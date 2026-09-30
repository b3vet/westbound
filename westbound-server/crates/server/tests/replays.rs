//! N8.1 replays: the upload endpoint (auth, owner, size cap, only when the receipt asked,
//! header checks, idempotency), the verification queue with a stand-in verifier script
//! (verdicts, placeholders, one job at a time, timeouts, retries, restart recovery, the
//! no-verifier mode), retention (top N keeps its file, orphans) and, `#[ignore]`d, the
//! end-to-end path with the real Godot verifier. docs/SERVER.md → "Replays and
//! verification".

mod common;

use std::path::{Path, PathBuf};
use std::time::Duration;

use common::*;
use serde_json::{json, Value};
use westbound_server::clock::Clock;
use westbound_server::replays::format::{self, Header};
use westbound_server::replays::retention;
use westbound_server::replays::worker::JobOutcome;
use westbound_server::Config;

// ---------------------------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------------------------

/// A header matching `journey_run` (seed 123456789, T0's date, build 1) for `run_id`.
fn header(run_id: i64) -> Header {
    Header {
        run_id,
        seed: 123_456_789,
        client_build: 1,
        tuning_hash: 0x1234_5678,
        mode: "journey",
        tick_hz: 120,
        sample_ticks: 4,
        date: T0_DATE.to_string(),
        ticks: 48_000,
        score: 42_000,
        hits: 1,
        distance_mm: 20_000_000,
        raw_len: 100,
        payload_len: 0,
        car: "coupe".to_string(),
        header_len: 0,
    }
}

/// A replay file for `h` with `extra` payload bytes after a gzip magic.
fn replay(h: &Header, extra: usize) -> Vec<u8> {
    let mut payload = vec![0x1f, 0x8b, 8, 0];
    payload.extend((0..extra).map(|i| (i % 251) as u8));
    format::build(h, &payload)
}

impl TestApp {
    async fn upload(&self, token: Option<&str>, run_id: &str, body: Vec<u8>) -> Resp {
        let auth = token.map(|t| format!("Bearer {t}"));
        let mut headers: Vec<(&str, &str)> = vec![("content-type", "application/octet-stream")];
        if let Some(a) = &auth {
            headers.push(("authorization", a));
        }
        self.raw(
            "POST",
            &format!("/api/v1/runs/{run_id}/replay"),
            CLIENT,
            &headers,
            body,
        )
        .await
    }

    /// A pending run (a first Journey run: replay required): (run id, token).
    async fn pending_run(&self, key: &str, score: u64) -> (i64, String, i64) {
        let (account, tok) = self.account().await;
        let r = self
            .submit_ok(&tok, journey_run(key, score, 20_000.0))
            .await;
        assert_eq!(r["replay_required"], true);
        (r["run_id"].as_str().unwrap().parse().unwrap(), tok, account)
    }

    async fn job(&self, run_id: i64) -> Option<(String, i64, Option<String>, Option<i64>)> {
        sqlx::query_as::<_, (String, i64, Option<String>, Option<i64>)>(
            "SELECT status, attempts, verdict, file_deleted_at FROM replays WHERE run_id = ?",
        )
        .bind(run_id)
        .fetch_optional(self.db())
        .await
        .unwrap()
    }

    async fn job_result(&self, run_id: i64) -> String {
        sqlx::query_scalar::<_, Option<String>>("SELECT result FROM replays WHERE run_id = ?")
            .bind(run_id)
            .fetch_one(self.db())
            .await
            .unwrap()
            .unwrap_or_default()
    }

    async fn verification(&self, run_id: i64) -> String {
        sqlx::query_scalar("SELECT verification FROM runs WHERE id = ?")
            .bind(run_id)
            .fetch_one(self.db())
            .await
            .unwrap()
    }
}

fn replay_file(app: &TestApp, run_id: i64) -> PathBuf {
    app.state.config.replays.dir.join(format!("{run_id}.wbr"))
}

/// A stand-in verifier: a shell script in its own temp dir. `body` sees the argv as
/// `$1 = {out}`, `$2 = {replay}`, `$3 = {seed}`, `$4 = {claimed_score}`,
/// `$5 = {claimed_hits}`, `$6 = {run_id}`, and `$DIR` (the script's directory).
#[cfg(unix)]
struct Script {
    dir: tempfile::TempDir,
}

#[cfg(unix)]
impl Script {
    fn new(body: &str) -> Script {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("verifier.sh");
        std::fs::write(
            &path,
            format!(
                "#!/bin/sh\nDIR='{}'\n{body}\n",
                dir.path().to_string_lossy()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        Script { dir }
    }

    fn command(&self) -> Vec<String> {
        [
            self.dir
                .path()
                .join("verifier.sh")
                .to_string_lossy()
                .as_ref(),
            "{out}",
            "{replay}",
            "{seed}",
            "{claimed_score}",
            "{claimed_hits}",
            "{run_id}",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect()
    }

    fn file(&self, name: &str) -> PathBuf {
        self.dir.path().join(name)
    }
}

#[cfg(unix)]
const ACCEPT: &str = r#"echo '{"accepted":true,"reason":"accepted","recomputed_score":41990,"diff_pct":0.024,"unreported_hits":0,"violations":[]}' > "$1"; exit 0"#;
#[cfg(unix)]
const REJECT: &str = r#"echo '{"accepted":false,"reason":"unreported_hits","recomputed_score":30000,"diff_pct":28.6,"unreported_hits":2,"violations":[]}' > "$1"; exit 1"#;

#[cfg(unix)]
async fn app_with_verifier(script: &Script, tweak: impl FnOnce(&mut Config)) -> TestApp {
    let cmd = script.command();
    app_with(move |c| {
        long_tokens(c);
        c.replays.verifier_command = cmd;
        c.replays.retry_delay_secs = 60;
        tweak(c);
    })
    .await
}

// ---------------------------------------------------------------------------------------------
// Upload
// ---------------------------------------------------------------------------------------------

#[tokio::test]
async fn upload_needs_the_owner_and_stores_the_file_once() {
    let app = runs_app().await;
    let (run_id, tok, _) = app.pending_run("rep-00001", 42_000).await;
    let bytes = replay(&header(run_id), 500);
    let id = run_id.to_string();
    assert_error(
        &app.upload(None, &id, bytes.clone()).await,
        401,
        "unauthorized",
    );
    assert_error(
        &app.upload(Some(&tok), "abc", bytes.clone()).await,
        404,
        "unknown_run",
    );
    assert_error(
        &app.upload(Some(&tok), "999999", bytes.clone()).await,
        404,
        "unknown_run",
    );
    let (_, other) = app.account().await;
    assert_error(
        &app.upload(Some(&other), &id, bytes.clone()).await,
        403,
        "not_owner",
    );

    let r = app.upload(Some(&tok), &id, bytes.clone()).await;
    assert_eq!(r.status, 201, "{:?}", r.json);
    assert_eq!(r.json["run_id"], id);
    assert_eq!(r.json["status"], "pending");
    assert_eq!(r.json["duplicate"], false);
    assert_eq!(r.json["size_bytes"], bytes.len() as u64);
    let path = replay_file(&app, run_id);
    assert_eq!(std::fs::read(&path).unwrap(), bytes, "stored as sent");
    assert_eq!(app.job(run_id).await.unwrap().0, "pending");
    let stored: String = sqlx::query_scalar("SELECT file_path FROM replays WHERE run_id = ?")
        .bind(run_id)
        .fetch_one(app.db())
        .await
        .unwrap();
    assert_eq!(Path::new(&stored), path);

    // Idempotent: a second upload (even other bytes) answers the first and stores nothing.
    let again = app
        .upload(Some(&tok), &id, replay(&header(run_id), 900))
        .await;
    assert_eq!(again.status, 200, "{:?}", again.json);
    assert_eq!(again.json["duplicate"], true);
    assert_eq!(again.json["size_bytes"], bytes.len() as u64);
    assert_eq!(std::fs::read(&path).unwrap(), bytes, "unchanged");
    let files = std::fs::read_dir(&app.state.config.replays.dir)
        .unwrap()
        .count();
    assert_eq!(files, 1, "no temporary file left behind");
}

#[tokio::test]
async fn upload_only_when_the_receipt_asked_for_it() {
    let app = runs_app().await;
    let (_, tok) = app.account().await;
    let first = app
        .submit_ok(&tok, journey_run("req-00001", 9_000, 21_000.0))
        .await;
    assert_eq!(first["replay_required"], true);
    // A lower second run improves nothing: no replay needed.
    let second = app
        .submit_ok(&tok, journey_run("req-00002", 5_000, 20_000.0))
        .await;
    assert_eq!(second["replay_required"], false);
    let id = second["run_id"].as_str().unwrap();
    let bytes = replay(&header(id.parse().unwrap()), 10);
    assert_error(
        &app.upload(Some(&tok), id, bytes).await,
        409,
        "replay_not_required",
    );
    // A rejected run (plausibility) needs none either.
    let mut bad = journey_run("req-00003", 90_000_000, 20_000.0);
    bad["score"] = json!(90_000_000);
    let rejected = app.submit_ok(&tok, bad).await;
    assert_eq!(rejected["verification"], "rejected");
    let rid = rejected["run_id"].as_str().unwrap();
    assert_error(
        &app.upload(Some(&tok), rid, replay(&header(rid.parse().unwrap()), 10))
            .await,
        409,
        "replay_not_required",
    );
}

#[tokio::test]
async fn upload_checks_the_header_is_this_runs() {
    let app = runs_app().await;
    let (run_id, tok, _) = app.pending_run("hdr-00001", 42_000).await;
    let id = run_id.to_string();
    assert_error(
        &app.upload(
            Some(&tok),
            &id,
            b"not a replay at all, just some bytes".repeat(4),
        )
        .await,
        400,
        "invalid_replay",
    );
    let mut truncated = replay(&header(run_id), 100);
    truncated.truncate(truncated.len() - 3);
    assert_error(
        &app.upload(Some(&tok), &id, truncated).await,
        400,
        "invalid_replay",
    );
    type Edit = Box<dyn Fn(&mut Header)>;
    let cases: Vec<(&str, Edit)> = vec![
        ("run id", Box::new(|h: &mut Header| h.run_id += 1)),
        ("run id 0", Box::new(|h: &mut Header| h.run_id = 0)),
        ("seed", Box::new(|h: &mut Header| h.seed = 5)),
        ("mode", Box::new(|h: &mut Header| h.mode = "daily")),
        (
            "date",
            Box::new(|h: &mut Header| h.date = "2026-09-20".into()),
        ),
        ("build", Box::new(|h: &mut Header| h.client_build = 2)),
    ];
    for (what, edit) in cases {
        let mut h = header(run_id);
        edit(&mut h);
        let r = app.upload(Some(&tok), &id, replay(&h, 10)).await;
        assert_error(&r, 400, "replay_mismatch");
        assert!(app.job(run_id).await.is_none(), "{what}: nothing stored");
    }
    let r = app
        .upload(Some(&tok), &id, replay(&header(run_id), 10))
        .await;
    assert_eq!(r.status, 201, "{:?}", r.json);
}

#[tokio::test]
async fn upload_size_is_capped() {
    let app = app_with(|c| {
        long_tokens(c);
        c.replays.max_bytes = 2_048;
    })
    .await;
    let (run_id, tok, _) = app.pending_run("cap-00001", 42_000).await;
    let id = run_id.to_string();
    let r = app
        .upload(Some(&tok), &id, replay(&header(run_id), 3_000))
        .await;
    assert_error(&r, 413, "body_too_large");
    assert!(app.job(run_id).await.is_none());
    // Just under the cap is fine (bigger than the JSON routes' 4 KB default would allow
    // too: that limit does not apply here).
    let bytes = replay(&header(run_id), 1_800);
    assert!(bytes.len() <= 2_048);
    let r = app.upload(Some(&tok), &id, bytes).await;
    assert_eq!(r.status, 201, "{:?}", r.json);
}

#[tokio::test]
async fn large_replays_pass_the_default_cap() {
    let app = runs_app().await;
    let (run_id, tok, _) = app.pending_run("big-00001", 42_000).await;
    // 300 KB: far above the JSON body limit, well under replays.max_bytes (4 MiB).
    let bytes = replay(&header(run_id), 300_000);
    let r = app.upload(Some(&tok), &run_id.to_string(), bytes).await;
    assert_eq!(r.status, 201, "{:?}", r.json);
}

// ---------------------------------------------------------------------------------------------
// The queue
// ---------------------------------------------------------------------------------------------

#[tokio::test]
async fn without_a_verifier_jobs_wait_and_runs_stay_verifying() {
    let app = runs_app().await;
    let (run_id, tok, _) = app.pending_run("nov-00001", 42_000).await;
    let r = app
        .upload(Some(&tok), &run_id.to_string(), replay(&header(run_id), 10))
        .await;
    assert_eq!(r.status, 201);
    let worker = app.state.replay_worker();
    assert!(!worker.configured());
    assert!(worker.run_next().await.unwrap().is_none(), "nothing runs");
    assert_eq!(app.job(run_id).await.unwrap().0, "pending");
    assert_eq!(app.verification(run_id).await, "pending");
    let b = app.board_ok(None, "journey?period=all").await;
    assert_eq!(b["entries"][0]["verifying"], true, "shown as verifying");
    assert!(replay_file(&app, run_id).exists(), "the file waits too");
}

#[cfg(unix)]
#[tokio::test]
async fn accepted_verdict_verifies_the_run_and_keeps_a_top_replay() {
    let script = Script::new(&format!(r#"echo "$@" > "$DIR/args"; {ACCEPT}"#));
    let app = app_with_verifier(&script, |_| {}).await;
    let (run_id, tok, _) = app.pending_run("acc-00001", 42_000).await;
    app.upload(Some(&tok), &run_id.to_string(), replay(&header(run_id), 10))
        .await;
    let worker = app.state.replay_worker();
    let (id, outcome) = worker.run_next().await.unwrap().expect("a job ran");
    assert_eq!(id, run_id);
    let JobOutcome::Verdict { accepted, result } = outcome else {
        panic!("a verdict: {outcome:?}");
    };
    assert!(accepted);
    assert_eq!(result["recomputed_score"], 41_990);
    assert_eq!(app.verification(run_id).await, "verified");
    let b = app.board_ok(None, "journey?period=all").await;
    assert_eq!(b["entries"][0]["verification"], "verified");
    assert_eq!(b["entries"][0]["verifying"], false);
    let (status, attempts, verdict, deleted) = app.job(run_id).await.unwrap();
    assert_eq!(
        (status.as_str(), attempts, verdict.as_deref()),
        ("done", 1, Some("accepted"))
    );
    assert!(deleted.is_none(), "rank 1: kept");
    assert!(replay_file(&app, run_id).exists());
    let stored: String = sqlx::query_scalar("SELECT result FROM replays WHERE run_id = ?")
        .bind(run_id)
        .fetch_one(app.db())
        .await
        .unwrap();
    let stored: Value = serde_json::from_str(&stored).unwrap();
    assert_eq!(stored["reason"], "accepted");
    // The placeholders.
    let args = std::fs::read_to_string(script.file("args")).unwrap();
    let args: Vec<&str> = args.split_whitespace().collect();
    assert!(
        args[0].ends_with(&format!("work/{run_id}.json")),
        "{args:?}"
    );
    assert_eq!(Path::new(args[1]), replay_file(&app, run_id));
    assert_eq!(&args[2..], ["123456789", "42000", "1", &run_id.to_string()]);
    assert!(
        worker.run_next().await.unwrap().is_none(),
        "the queue is empty"
    );
}

#[cfg(unix)]
#[tokio::test]
async fn rejected_verdict_rejects_the_run_and_deletes_the_replay() {
    let script = Script::new(REJECT);
    let app = app_with_verifier(&script, |_| {}).await;
    let (run_id, tok, _) = app.pending_run("rej-00001", 42_000).await;
    app.upload(Some(&tok), &run_id.to_string(), replay(&header(run_id), 10))
        .await;
    let (_, outcome) = app.state.replay_worker().run_next().await.unwrap().unwrap();
    assert!(matches!(
        outcome,
        JobOutcome::Verdict {
            accepted: false,
            ..
        }
    ));
    assert_eq!(app.verification(run_id).await, "rejected");
    let b = app.board_ok(None, "journey?period=all").await;
    assert!(b["entries"].as_array().unwrap().is_empty(), "off the board");
    let (status, _, verdict, deleted) = app.job(run_id).await.unwrap();
    assert_eq!(
        (status.as_str(), verdict.as_deref()),
        ("done", Some("rejected"))
    );
    assert!(deleted.is_some(), "not in a top list: the file goes");
    assert!(!replay_file(&app, run_id).exists());
}

#[cfg(unix)]
#[tokio::test]
async fn a_verifier_that_runs_over_is_killed_and_retried_then_failed() {
    let script = Script::new(r#"echo $$ > "$DIR/pid"; sleep 3; touch "$DIR/finished""#);
    let app = app_with_verifier(&script, |c| {
        c.replays.job_timeout_secs = 1;
        c.replays.max_attempts = 2;
    })
    .await;
    let (run_id, tok, _) = app.pending_run("tmo-00001", 42_000).await;
    app.upload(Some(&tok), &run_id.to_string(), replay(&header(run_id), 10))
        .await;
    let worker = app.state.replay_worker();
    let started = std::time::Instant::now();
    let (_, outcome) = worker.run_next().await.unwrap().unwrap();
    assert!(
        started.elapsed() < Duration::from_millis(2_500),
        "cut at the timeout"
    );
    let JobOutcome::Failed { error, final_ } = outcome else {
        panic!("{outcome:?}")
    };
    assert!(error.contains("ran over"), "{error}");
    assert!(!final_, "one attempt left");
    assert_eq!(app.job(run_id).await.unwrap().0, "pending");
    assert!(
        worker.run_next().await.unwrap().is_none(),
        "not before the retry delay"
    );
    app.clock.advance(60);
    let (_, outcome) = worker.run_next().await.unwrap().unwrap();
    assert!(matches!(outcome, JobOutcome::Failed { final_: true, .. }));
    let (status, attempts, verdict, _) = app.job(run_id).await.unwrap();
    assert_eq!((status.as_str(), attempts, verdict), ("failed", 2, None));
    assert_eq!(
        app.verification(run_id).await,
        "pending",
        "the run stays verifying"
    );
    assert!(
        replay_file(&app, run_id).exists(),
        "failed jobs keep their file"
    );
    // The process was killed: it never finished its sleep.
    tokio::time::sleep(Duration::from_millis(2_500)).await;
    assert!(!script.file("finished").exists(), "killed at the timeout");
}

#[cfg(unix)]
#[tokio::test]
async fn a_failed_attempt_is_retried() {
    // First run: no result and exit 3 (another build). Second: accepted.
    let script = Script::new(&format!(
        r#"if [ ! -f "$DIR/once" ]; then touch "$DIR/once"; echo "tuning_mismatch" >&2; exit 3; fi; {ACCEPT}"#
    ));
    let app = app_with_verifier(&script, |c| c.replays.retry_delay_secs = 0).await;
    let (run_id, tok, _) = app.pending_run("rty-00001", 42_000).await;
    app.upload(Some(&tok), &run_id.to_string(), replay(&header(run_id), 10))
        .await;
    let worker = app.state.replay_worker();
    let (_, first) = worker.run_next().await.unwrap().unwrap();
    let JobOutcome::Failed { error, final_ } = first else {
        panic!("{first:?}")
    };
    assert!(!final_);
    assert!(
        error.contains("exit Some(3)") && error.contains("tuning_mismatch"),
        "the exit status and the output tail: {error}"
    );
    let (_, second) = worker.run_next().await.unwrap().unwrap();
    assert!(matches!(second, JobOutcome::Verdict { accepted: true, .. }));
    let (status, attempts, _, _) = app.job(run_id).await.unwrap();
    assert_eq!((status.as_str(), attempts), ("done", 2));
    assert_eq!(app.verification(run_id).await, "verified");
}

#[cfg(unix)]
#[tokio::test]
async fn a_verdict_that_contradicts_the_exit_status_is_no_verdict() {
    let script = Script::new(r#"echo '{"accepted":true}' > "$1"; exit 1"#);
    let app = app_with_verifier(&script, |c| c.replays.max_attempts = 1).await;
    let (run_id, tok, _) = app.pending_run("bad-00001", 42_000).await;
    app.upload(Some(&tok), &run_id.to_string(), replay(&header(run_id), 10))
        .await;
    let (_, outcome) = app.state.replay_worker().run_next().await.unwrap().unwrap();
    assert!(matches!(outcome, JobOutcome::Failed { final_: true, .. }));
    assert_eq!(app.verification(run_id).await, "pending");
}

#[cfg(unix)]
#[tokio::test]
async fn jobs_left_running_are_requeued_on_start() {
    let script = Script::new(ACCEPT);
    let app = app_with_verifier(&script, |_| {}).await;
    let (run_id, tok, _) = app.pending_run("rcv-00001", 42_000).await;
    app.upload(Some(&tok), &run_id.to_string(), replay(&header(run_id), 10))
        .await;
    sqlx::query("UPDATE replays SET status = 'running', attempts = 1 WHERE run_id = ?")
        .bind(run_id)
        .execute(app.db())
        .await
        .unwrap();
    let worker = app.state.replay_worker();
    assert!(
        worker.run_next().await.unwrap().is_none(),
        "running: not picked"
    );
    assert_eq!(worker.recover().await.unwrap(), 1);
    let (_, outcome) = worker.run_next().await.unwrap().unwrap();
    assert!(matches!(
        outcome,
        JobOutcome::Verdict { accepted: true, .. }
    ));
    assert_eq!(
        app.job(run_id).await.unwrap().1,
        2,
        "the lost attempt counts"
    );
}

/// N8.3: a verifier command that names a per-build file (`/verifier/{build}/westbound`)
/// whose build is not in this worker: the job is set aside at once, without running
/// anything and without a retry loop; the run stays verifying. A worker that starts with
/// that build (a new verifier image) takes it up again.
#[cfg(unix)]
#[tokio::test]
async fn a_build_without_a_verifier_is_set_aside_until_a_worker_has_it() {
    let script = Script::new(&format!(r#"touch "$DIR/ran"; {ACCEPT}"#));
    let builds = script.file("builds");
    let per_build = format!("{}/{{build}}/westbound", builds.display());
    let app = app_with_verifier(&script, |c| {
        c.replays.verifier_command.push(per_build);
        c.replays.max_attempts = 3;
    })
    .await;
    let (run_id, tok, _) = app.pending_run("nob-00001", 42_000).await;
    app.upload(Some(&tok), &run_id.to_string(), replay(&header(run_id), 10))
        .await;
    let worker = app.state.replay_worker();
    let (_, outcome) = worker.run_next().await.unwrap().unwrap();
    let JobOutcome::Unverifiable { error } = outcome else {
        panic!("{outcome:?}")
    };
    assert!(
        error.contains("no verifier for build 1") && error.contains("/1/westbound"),
        "{error}"
    );
    assert!(!script.file("ran").exists(), "nothing was run");
    let (status, _, verdict, deleted) = app.job(run_id).await.unwrap();
    assert_eq!((status.as_str(), verdict, deleted), ("failed", None, None));
    let result: Value = serde_json::from_str(&app.job_result(run_id).await).unwrap();
    assert_eq!(result["unverifiable"], true, "{result}");
    assert_eq!(result["build"], 1, "{result}");
    assert_eq!(app.verification(run_id).await, "pending", "still verifying");
    assert!(replay_file(&app, run_id).exists(), "the file is kept");
    app.clock.advance(3_600);
    assert!(
        worker.run_next().await.unwrap().is_none(),
        "no retry loop: set aside until a worker starts"
    );

    // Still no build 1: a restarted worker puts it back, and it is set aside again.
    assert_eq!(worker.requeue_unverifiable().await.unwrap(), 1);
    let (_, again) = worker.run_next().await.unwrap().unwrap();
    assert!(
        matches!(again, JobOutcome::Unverifiable { .. }),
        "{again:?}"
    );

    // A worker (a new image) with build 1: verified.
    std::fs::create_dir_all(builds.join("1")).unwrap();
    std::fs::write(builds.join("1/westbound"), b"").unwrap();
    assert_eq!(worker.requeue_unverifiable().await.unwrap(), 1);
    let (_, outcome) = worker.run_next().await.unwrap().unwrap();
    assert!(
        matches!(outcome, JobOutcome::Verdict { accepted: true, .. }),
        "{outcome:?}"
    );
    assert!(script.file("ran").exists());
    assert_eq!(app.verification(run_id).await, "verified");
}

/// N8.3: the verifier's "cannot verify" (exit 3 with a result `error`: another tuning
/// under the same build number, a replay without inputs, an unknown car) is not retried
/// against the same verifier: the job is set aside at once with the verifier's reason.
#[cfg(unix)]
#[tokio::test]
async fn a_replay_this_verifier_cannot_verify_is_set_aside_at_once() {
    let script = Script::new(&format!(
        r#"if [ ! -f "$DIR/once" ]; then touch "$DIR/once"; echo '{{"error":"tuning_mismatch: another tuning"}}' > "$1"; exit 3; fi; {ACCEPT}"#
    ));
    let app = app_with_verifier(&script, |c| {
        c.replays.max_attempts = 3;
        c.replays.retry_delay_secs = 0;
    })
    .await;
    let (run_id, tok, _) = app.pending_run("cnv-00001", 42_000).await;
    app.upload(Some(&tok), &run_id.to_string(), replay(&header(run_id), 10))
        .await;
    let worker = app.state.replay_worker();
    let (_, outcome) = worker.run_next().await.unwrap().unwrap();
    let JobOutcome::Unverifiable { error } = outcome else {
        panic!("{outcome:?}")
    };
    assert!(error.contains("tuning_mismatch"), "{error}");
    assert_eq!(app.job(run_id).await.unwrap().0, "failed");
    let result: Value = serde_json::from_str(&app.job_result(run_id).await).unwrap();
    assert_eq!(result["unverifiable"], true, "{result}");
    assert!(
        worker.run_next().await.unwrap().is_none(),
        "not retried against the same verifier"
    );
    assert_eq!(app.verification(run_id).await, "pending");

    // A job that failed for good otherwise stays failed (the operator requeues it).
    let plain = Script::new("exit 7");
    let other = app_with_verifier(&plain, |c| c.replays.max_attempts = 1).await;
    let (other_run, other_tok, _) = other.pending_run("cnv-00002", 42_000).await;
    other
        .upload(
            Some(&other_tok),
            &other_run.to_string(),
            replay(&header(other_run), 10),
        )
        .await;
    let other_worker = other.state.replay_worker();
    other_worker.run_next().await.unwrap().unwrap();
    assert_eq!(other.job(other_run).await.unwrap().0, "failed");
    assert_eq!(other_worker.requeue_unverifiable().await.unwrap(), 0);

    assert_eq!(worker.requeue_unverifiable().await.unwrap(), 1);
    let (_, outcome) = worker.run_next().await.unwrap().unwrap();
    assert!(
        matches!(outcome, JobOutcome::Verdict { accepted: true, .. }),
        "{outcome:?}"
    );
    assert_eq!(app.verification(run_id).await, "verified");
}

/// The real server's worker task: three uploads, one verifier process at a time, in
/// upload order.
#[cfg(unix)]
#[tokio::test]
async fn the_server_runs_one_job_at_a_time_in_order() {
    let script = Script::new(&format!(
        r#"if ! mkdir "$DIR/lock" 2>/dev/null; then touch "$DIR/overlap"; fi
echo "$6" >> "$DIR/order"
sleep 0.3
rmdir "$DIR/lock"
{ACCEPT}"#
    ));
    let cmd = script.command();
    let server = start_with(move |c| {
        c.replays.verifier_command = cmd;
        c.replays.poll_interval_secs = 60;
    })
    .await;
    let base = format!("http://{}", server.addr);
    let http = HttpClient::new();
    let mut ids = Vec::new();
    for i in 0..3 {
        let tok = http.device_token(&base).await;
        let mut body = journey_run(&format!("seq-0000{i}"), 42_000, 20_000.0);
        body["date"] = json!(run_date_today());
        let run = http.post_json(&base, "/api/v1/runs", &tok, body).await;
        assert_eq!(run["replay_required"], true, "{run}");
        let run_id: i64 = run["run_id"].as_str().unwrap().parse().unwrap();
        let mut h = header(run_id);
        h.date = run_date_today();
        let status = http
            .post_bytes(
                &base,
                &format!("/api/v1/runs/{run_id}/replay"),
                &tok,
                replay(&h, 10),
            )
            .await;
        assert_eq!(status, 201);
        ids.push(run_id);
    }
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        let done: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM replays WHERE status = 'done'")
            .fetch_one(&server.state.db)
            .await
            .unwrap();
        if done == 3 {
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "all three verified");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(!script.file("overlap").exists(), "never two at once");
    let order: Vec<i64> = std::fs::read_to_string(script.file("order"))
        .unwrap()
        .lines()
        .map(|l| l.trim().parse().unwrap())
        .collect();
    assert_eq!(order, ids, "oldest first");
    server.stop().await;
}

// ---------------------------------------------------------------------------------------------
// Retention
// ---------------------------------------------------------------------------------------------

#[cfg(unix)]
#[tokio::test]
async fn retention_keeps_top_n_replays_and_removes_orphans() {
    let script = Script::new(ACCEPT);
    let app = app_with_verifier(&script, |c| c.replays.keep_top_n = 1).await;
    let worker = app.state.replay_worker();
    let (a, tok_a, _) = app.pending_run("ret-00001", 42_000).await;
    app.upload(Some(&tok_a), &a.to_string(), replay(&header(a), 10))
        .await;
    worker.run_next().await.unwrap().unwrap();
    assert!(replay_file(&app, a).exists(), "rank 1 of top 1: kept");
    // A better and longer run by someone else pushes it to rank 2 everywhere (a tie on
    // Distance would keep the earlier run first).
    let (_, tok_b) = app.account().await;
    let rb = app
        .submit_ok(&tok_b, journey_run("ret-00002", 50_000, 21_000.0))
        .await;
    let b: i64 = rb["run_id"].as_str().unwrap().parse().unwrap();
    let mut hb = header(b);
    hb.score = 50_000;
    app.upload(Some(&tok_b), &b.to_string(), replay(&hb, 10))
        .await;
    worker.run_next().await.unwrap().unwrap();
    // Orphans: an old file of no job, an old temporary file; a fresh stray stays.
    let dir = app.state.config.replays.dir.clone();
    let old = std::time::SystemTime::now() - Duration::from_secs(7_200);
    for name in ["999999.wbr", "5.wbr.abcd.tmp"] {
        let f = std::fs::File::create(dir.join(name)).unwrap();
        f.set_modified(old).unwrap();
    }
    std::fs::write(dir.join("888888.wbr"), b"fresh").unwrap();
    let report = retention::sweep(app.db(), &app.state.config.replays, app.clock.now() + 10)
        .await
        .unwrap();
    assert_eq!(report.deleted, 1, "{report:?}");
    assert_eq!(report.kept, 1);
    assert_eq!(report.orphans, 2);
    assert!(!replay_file(&app, a).exists(), "out of the top 1: deleted");
    assert!(
        app.job(a).await.unwrap().3.is_some(),
        "the row remembers it"
    );
    assert!(replay_file(&app, b).exists(), "the new top: kept");
    assert!(!dir.join("999999.wbr").exists());
    assert!(!dir.join("5.wbr.abcd.tmp").exists());
    assert!(dir.join("888888.wbr").exists(), "younger than an hour");
    // Nothing left to do.
    let again = retention::sweep(app.db(), &app.state.config.replays, app.clock.now() + 20)
        .await
        .unwrap();
    assert_eq!((again.deleted, again.orphans), (0, 0));
}

#[tokio::test]
async fn account_deletion_removes_uploaded_replays() {
    let app = runs_app().await;
    let (run_id, tok, _) = app.pending_run("del-00001", 42_000).await;
    app.upload(Some(&tok), &run_id.to_string(), replay(&header(run_id), 10))
        .await;
    assert!(replay_file(&app, run_id).exists());
    let r = app
        .call("DELETE", "/api/v1/account", Some(&tok), None)
        .await;
    assert_eq!(r.status, 204, "{:?}", r.json);
    assert!(
        !replay_file(&app, run_id).exists(),
        "the file went with the account"
    );
    assert!(app.job(run_id).await.is_none());
}

// ---------------------------------------------------------------------------------------------
// End to end with the real verifier (Godot)
// ---------------------------------------------------------------------------------------------

/// Records a short real run with Godot (tools/verifier/record_sample_replay.gd), submits
/// it to a real server whose verifier command is the Godot verifier, uploads the replay
/// and waits for the verdict. Needs Godot (tools/godot.sh downloads it) and about a
/// minute:
///   cargo test -p server --test replays -- --ignored end_to_end
/// `WB_GODOT` overrides the Godot launcher (default: <repo>/tools/godot.sh).
#[cfg(unix)]
#[tokio::test]
#[ignore = "needs Godot: cargo test -p server --test replays -- --ignored"]
async fn end_to_end_with_the_godot_verifier() {
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let repo = repo.canonicalize().unwrap();
    let godot = std::env::var("WB_GODOT")
        .unwrap_or_else(|_| repo.join("tools/godot.sh").to_string_lossy().into_owned());
    let work = tempfile::tempdir().unwrap();
    let sample = work.path().join("sample.wbr");
    let claims = work.path().join("sample.json");
    let today = run_date_today();
    let st = std::process::Command::new(&godot)
        .args(["--headless", "--path"])
        .arg(&repo)
        .args([
            "--script",
            "res://tools/verifier/record_sample_replay.gd",
            "--",
        ])
        .arg(format!("--out={}", sample.display()))
        .arg(format!("--claims={}", claims.display()))
        .arg(format!("--date={today}"))
        .args(["--seconds=20", "--seed=20260929", "--server=off"])
        .status()
        .expect("running Godot");
    assert!(st.success(), "recording the sample replay");
    let claims: Value = serde_json::from_slice(&std::fs::read(&claims).unwrap()).unwrap();
    let mut bytes = std::fs::read(&sample).unwrap();

    let cmd: Vec<String> = [
        godot.as_str(),
        "--headless",
        "--path",
        repo.to_str().unwrap(),
        "--script",
        "res://tools/verifier/verify_replay.gd",
        "--",
        "--server=off",
        "--replay={replay}",
        "--out={out}",
        "--seed={seed}",
        "--claimed-score={claimed_score}",
        "--claimed-hits={claimed_hits}",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    let server = start_with(move |c| {
        c.replays.verifier_command = cmd;
        c.replays.job_timeout_secs = 300;
    })
    .await;
    let base = format!("http://{}", server.addr);
    let http = HttpClient::new();
    let tok = http.device_token(&base).await;
    let mut run = journey_run("e2e-000001", claims["score"].as_u64().unwrap(), 2_000.0);
    run["seed"] = claims["seed"].clone();
    run["date"] = json!(today);
    run["car"] = claims["car"].clone();
    run["client_build"] = claims["client_build"].clone();
    run["hits"] = claims["hits"].clone();
    run["duration_s"] = claims["duration_s"].clone();
    run["distance_m"] = claims["distance_m"].clone();
    run["legs_completed"] = json!(0);
    run["passes"] = json!(1000);
    let receipt = http.post_json(&base, "/api/v1/runs", &tok, run).await;
    assert_eq!(receipt["replay_required"], true, "{receipt}");
    let run_id: i64 = receipt["run_id"].as_str().unwrap().parse().unwrap();
    assert!(format::patch_run_id(&mut bytes, run_id));
    let status = http
        .post_bytes(&base, &format!("/api/v1/runs/{run_id}/replay"), &tok, bytes)
        .await;
    assert_eq!(status, 201);
    let deadline = tokio::time::Instant::now() + Duration::from_secs(300);
    let verdict = loop {
        let row: Option<(String, Option<String>, Option<String>)> =
            sqlx::query_as("SELECT status, verdict, result FROM replays WHERE run_id = ?")
                .bind(run_id)
                .fetch_optional(&server.state.db)
                .await
                .unwrap();
        if let Some((status, verdict, result)) = row {
            if status == "done" || status == "failed" {
                break (status, verdict, result);
            }
        }
        assert!(tokio::time::Instant::now() < deadline, "a verdict in time");
        tokio::time::sleep(Duration::from_millis(200)).await;
    };
    assert_eq!(verdict.0, "done", "{:?}", verdict.2);
    assert_eq!(verdict.1.as_deref(), Some("accepted"), "{:?}", verdict.2);
    let v: String = sqlx::query_scalar("SELECT verification FROM runs WHERE id = ?")
        .bind(run_id)
        .fetch_one(&server.state.db)
        .await
        .unwrap();
    assert_eq!(v, "verified");
    server.stop().await;
}

// ---------------------------------------------------------------------------------------------
// A tiny HTTP/1.1 client for the real-server tests (no client crate in the workspace).
// ---------------------------------------------------------------------------------------------

/// Today's UTC date (the real server's clock).
fn run_date_today() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    westbound_server::clock::utc_date_string(now)
}

struct HttpClient;

impl HttpClient {
    fn new() -> Self {
        HttpClient
    }

    async fn send(
        &self,
        base: &str,
        method: &str,
        path: &str,
        headers: &[(&str, String)],
        body: Vec<u8>,
    ) -> (u16, Vec<u8>) {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let addr = base.trim_start_matches("http://");
        let mut s = tokio::net::TcpStream::connect(addr).await.unwrap();
        let mut req = format!(
            "{method} {path} HTTP/1.1\r\nHost: {addr}\r\nConnection: close\r\nContent-Length: {}\r\n",
            body.len()
        );
        for (k, v) in headers {
            req.push_str(&format!("{k}: {v}\r\n"));
        }
        req.push_str("\r\n");
        s.write_all(req.as_bytes()).await.unwrap();
        s.write_all(&body).await.unwrap();
        let mut buf = Vec::new();
        tokio::time::timeout(WAIT, s.read_to_end(&mut buf))
            .await
            .unwrap()
            .unwrap();
        let text = String::from_utf8_lossy(&buf);
        let status: u16 = text.split_whitespace().nth(1).unwrap().parse().unwrap();
        let split = buf.windows(4).position(|w| w == b"\r\n\r\n").unwrap() + 4;
        let head = String::from_utf8_lossy(&buf[..split]).to_ascii_lowercase();
        let mut body = buf[split..].to_vec();
        if head.contains("transfer-encoding: chunked") {
            body = dechunk(&body);
        }
        (status, body)
    }

    async fn device_token(&self, base: &str) -> String {
        let (status, body) = self
            .send(base, "POST", "/api/v1/auth/device", &[], Vec::new())
            .await;
        assert_eq!(status, 201);
        let v: Value = serde_json::from_slice(&body).unwrap();
        v["access_token"].as_str().unwrap().to_string()
    }

    async fn post_json(&self, base: &str, path: &str, token: &str, body: Value) -> Value {
        let (status, out) = self
            .send(
                base,
                "POST",
                path,
                &[
                    ("Authorization", format!("Bearer {token}")),
                    ("Content-Type", "application/json".to_string()),
                ],
                serde_json::to_vec(&body).unwrap(),
            )
            .await;
        let v: Value = serde_json::from_slice(&out).unwrap_or(Value::Null);
        assert!(status == 201 || status == 200, "{status} {v}");
        v
    }

    async fn post_bytes(&self, base: &str, path: &str, token: &str, body: Vec<u8>) -> u16 {
        self.send(
            base,
            "POST",
            path,
            &[
                ("Authorization", format!("Bearer {token}")),
                ("Content-Type", "application/octet-stream".to_string()),
            ],
            body,
        )
        .await
        .0
    }
}

fn dechunk(mut b: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    loop {
        let Some(eol) = b.windows(2).position(|w| w == b"\r\n") else {
            return out;
        };
        let size =
            usize::from_str_radix(std::str::from_utf8(&b[..eol]).unwrap().trim(), 16).unwrap();
        if size == 0 {
            return out;
        }
        out.extend_from_slice(&b[eol + 2..eol + 2 + size]);
        b = &b[eol + 2 + size + 2..];
    }
}
