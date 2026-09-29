//! `POST /api/v1/runs` and `/runs/legacy` (N7.1): the Daily seed port against GDScript,
//! every plausibility rejection, idempotency, the replay trigger, pending runs, legacy
//! uploads, rate limits and the account-deletion cascade.

mod common;

use common::*;
use serde_json::{json, Value};
use westbound_server::leaderboards::ReplayOutcome;
use westbound_server::runs::daily_seed;

// ---------------------------------------------------------------------------------------------
// Daily seed parity
// ---------------------------------------------------------------------------------------------

#[test]
fn daily_seed_matches_gdscript_vectors() {
    let v: Value =
        serde_json::from_str(include_str!("data/daily_seed_vectors.json")).expect("vectors");
    let daily = v["daily"].as_array().unwrap();
    assert!(
        daily.len() > 1_400,
        "every day of four years plus edge dates"
    );
    for d in daily {
        let date = d["date"].as_str().unwrap();
        let want: i64 = d["seed"].as_str().unwrap().parse().unwrap();
        assert_eq!(daily_seed::daily_seed_for_date(date), Some(want), "{date}");
    }
    let derive = v["derive"].as_array().unwrap();
    assert!(!derive.is_empty());
    for d in derive {
        let parent: i64 = d["parent"].as_str().unwrap().parse().unwrap();
        let name = d["name"].as_str().unwrap();
        let want: i64 = d["seed"].as_str().unwrap().parse().unwrap();
        assert_eq!(
            daily_seed::derive_seed(parent, name),
            want,
            "{parent}/{name}"
        );
        assert_eq!(
            u64::from(daily_seed::fnv1a32(name)),
            d["fnv1a32"].as_u64().unwrap(),
            "{name}"
        );
    }
}

// ---------------------------------------------------------------------------------------------
// Submissions
// ---------------------------------------------------------------------------------------------

#[tokio::test]
async fn first_journey_run_feeds_week_all_time_and_distance() {
    let app = runs_app().await;
    let (id, tok) = app.account().await;
    let r = app
        .submit_ok(&tok, journey_run("run-0001", 42_000, 20_500.7))
        .await;
    // A first run beats the (empty) personal best: replay, "verifying".
    assert_eq!(r["verification"], "pending");
    assert_eq!(r["verifying"], true);
    assert_eq!(r["replay_required"], true);
    assert_eq!(r["duplicate"], false);
    assert!(r["reason"].is_null());
    let p = r["placements"].as_array().unwrap();
    let got: Vec<(&str, &str, i64)> = p
        .iter()
        .map(|p| {
            (
                p["board"].as_str().unwrap(),
                p["period"].as_str().unwrap(),
                p["score"].as_i64().unwrap(),
            )
        })
        .collect();
    assert_eq!(
        got,
        vec![
            ("journey", "2026-W39", 42_000),
            ("journey", "all", 42_000),
            ("distance", "all", 20_500)
        ]
    );
    for p in p {
        assert_eq!(p["rank"], 1);
        assert_eq!(p["improved"], true);
        assert_eq!(p["on_board"], true);
        assert!(p["previous_best"].is_null());
    }
    let b = app.board_ok(None, "journey").await;
    assert_eq!(b["period"], "2026-W39");
    assert_eq!(b["period_kind"], "week");
    assert_eq!(b["period_start"], "2026-09-21");
    assert_eq!(b["period_end"], "2026-09-27");
    let e = &b["entries"][0];
    assert_eq!(e["account_id"], id.to_string());
    assert_eq!(e["verification"], "pending");
    assert_eq!(e["verifying"], true);
    assert_eq!(e["legacy"], false);
    assert_eq!(e["run_date"], T0_DATE);
    assert_eq!(e["run_id"], r["run_id"]);
    assert!(e["crew_tag"].is_null());
    assert!(e["full_name"].as_str().unwrap().contains('#'));
    let stored: (String, String, String) =
        sqlx::query_as("SELECT mode, map_or_seed, stats FROM runs WHERE id = ?")
            .bind(r["run_id"].as_str().unwrap().parse::<i64>().unwrap())
            .fetch_one(app.db())
            .await
            .unwrap();
    assert_eq!(
        (stored.0.as_str(), stored.1.as_str()),
        ("journey", "123456789")
    );
    let stats: Value = serde_json::from_str(&stored.2).unwrap();
    assert_eq!(stats["close_passes"], 50);
    assert_eq!(stats["top_speed_kmh"], 280.0);
}

#[tokio::test]
async fn seed_may_be_a_json_integer() {
    let app = runs_app().await;
    let (_, tok) = app.account().await;
    let mut body = journey_run("int-seed-1", 1_000, 20_000.0);
    body["seed"] = json!(9_223_372_036_854_775_807_i64);
    app.submit_ok(&tok, body).await;
    let mut neg = journey_run("int-seed-2", 1_000, 20_000.0);
    neg["seed"] = json!(-1);
    assert_error(&app.submit(&tok, neg).await, 400, "invalid_body");
}

#[tokio::test]
async fn idempotency_key_replays_the_first_answer() {
    let app = runs_app().await;
    let (_, tok) = app.account().await;
    let first = app
        .submit_ok(&tok, journey_run("same-key-1", 9_000, 20_000.0))
        .await;
    // Same key, even with another score: the first answer, 200, duplicate.
    let again = app
        .submit(&tok, journey_run("same-key-1", 99_000, 20_000.0))
        .await;
    assert_eq!(again.status, 200);
    assert_eq!(again.json["duplicate"], true);
    assert_eq!(again.json["run_id"], first["run_id"]);
    assert_eq!(again.json["placements"], first["placements"]);
    let n: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM runs")
        .fetch_one(app.db())
        .await
        .unwrap();
    assert_eq!(n, 1);
    let b = app.board_ok(None, "journey?period=all").await;
    assert_eq!(b["entries"][0]["score"], 9_000);
    // Keys are per account: another account may reuse it.
    let (_, other) = app.account().await;
    app.submit_ok(&other, journey_run("same-key-1", 5_000, 20_000.0))
        .await;
}

#[tokio::test]
async fn upsert_only_if_better() {
    let app = runs_app().await;
    let (_, tok) = app.account().await;
    app.submit_ok(&tok, journey_run("better-01", 5_000, 20_000.0))
        .await;
    let worse = app
        .submit_ok(&tok, journey_run("better-02", 3_000, 15_000.0))
        .await;
    for p in worse["placements"].as_array().unwrap() {
        assert_eq!(p["improved"], false);
        assert_eq!(p["on_board"], false);
        assert_eq!(p["rank"], 1);
    }
    assert_eq!(worse["placements"][0]["previous_best"], 5_000);
    // Not a personal best, and rank 1 is still the old entry: no replay needed.
    assert_eq!(worse["replay_required"], false);
    assert_eq!(worse["verification"], "unverified");
    // An equal score keeps the earlier run.
    let equal = app
        .submit_ok(&tok, journey_run("better-03", 5_000, 20_000.0))
        .await;
    assert_eq!(equal["placements"][1]["improved"], false);
    let b = app.board_ok(None, "journey?period=all").await;
    assert_eq!(ranking(&b)[0].1, 5_000);
    let first_run = b["entries"][0]["run_id"].clone();
    let better = app
        .submit_ok(&tok, journey_run("better-04", 7_000, 21_000.0))
        .await;
    assert_eq!(better["placements"][1]["improved"], true);
    assert_eq!(better["placements"][1]["previous_best"], 5_000);
    let b = app.board_ok(None, "journey?period=all").await;
    assert_eq!(b["total"], 1);
    assert_eq!(ranking(&b)[0].1, 7_000);
    assert_ne!(b["entries"][0]["run_id"], first_run);
    let d = app.board_ok(None, "distance").await;
    assert_eq!(ranking(&d)[0].1, 21_000);
}

#[tokio::test]
async fn replay_needed_for_top_n_or_personal_best_only() {
    let app = app_with(|c| {
        long_tokens(c);
        c.leaderboards.replay_top_n = 1;
    })
    .await;
    let (_, leader) = app.account().await;
    let (_, tok) = app.account().await;
    app.submit_ok(&leader, journey_run("lead-0001", 90_000, 30_000.0))
        .await;
    // Week 1: a personal best (all-time) → replay.
    let r = app
        .submit_ok(&tok, journey_run("mine-0001", 50_000, 25_000.0))
        .await;
    assert_eq!(r["replay_required"], true);
    // Next week: better than nothing this week but below the leader (rank 2 > top 1) and
    // below the all-time and distance bests → no replay, unverified, on the weekly board.
    app.clock.advance(7 * DAY);
    let date = "2026-09-28";
    app.submit_ok(&leader, {
        let mut v = journey_run("lead-0002", 80_000, 1_000.0);
        v["date"] = date.into();
        v["legs_completed"] = 0.into();
        v
    })
    .await;
    let mut body = journey_run("mine-0002", 10_000, 1_000.0);
    body["date"] = date.into();
    body["legs_completed"] = 0.into();
    let r = app.submit_ok(&tok, body).await;
    assert_eq!(r["verification"], "unverified");
    assert_eq!(r["replay_required"], false);
    assert_eq!(r["placements"][0]["period"], "2026-W40");
    assert_eq!(r["placements"][0]["improved"], true);
    assert_eq!(r["placements"][0]["rank"], 2);
    let b = app.board_ok(None, "journey").await;
    assert_eq!(b["period"], "2026-W40");
    assert_eq!(b["entries"][1]["verification"], "unverified");
    assert_eq!(b["entries"][1]["verifying"], false);
}

#[tokio::test]
async fn pending_runs_can_stay_off_the_boards_until_verified() {
    let app = app_with(|c| {
        long_tokens(c);
        c.leaderboards.show_pending = false;
    })
    .await;
    let (_, tok) = app.account().await;
    let r = app
        .submit_ok(&tok, journey_run("hold-0001", 12_000, 20_000.0))
        .await;
    assert_eq!(r["verification"], "pending");
    assert!(r["placements"]
        .as_array()
        .unwrap()
        .iter()
        .all(|p| p["on_board"] == false && p["improved"] == true));
    let b = app.board_ok(None, "journey?period=all").await;
    assert_eq!(b["total"], 0);
    let run_id: i64 = r["run_id"].as_str().unwrap().parse().unwrap();
    assert!(app
        .state
        .boards
        .set_run_verification(run_id, ReplayOutcome::Accepted)
        .await
        .unwrap());
    let b = app.board_ok(None, "journey?period=all").await;
    assert_eq!(b["entries"][0]["score"], 12_000);
    assert_eq!(b["entries"][0]["verification"], "verified");
    assert!(!app
        .state
        .boards
        .set_run_verification(999_999, ReplayOutcome::Accepted)
        .await
        .unwrap());
}

#[tokio::test]
async fn rejected_replay_falls_back_to_the_next_best_run() {
    let app = runs_app().await;
    let (_, tok) = app.account().await;
    let a = app
        .submit_ok(&tok, journey_run("fall-0001", 6_000, 20_000.0))
        .await;
    let b = app
        .submit_ok(&tok, journey_run("fall-0002", 9_000, 22_000.0))
        .await;
    let run_b: i64 = b["run_id"].as_str().unwrap().parse().unwrap();
    let board = app.board_ok(None, "journey?period=all").await;
    assert_eq!(board["entries"][0]["run_id"], b["run_id"]);
    app.state
        .boards
        .set_run_verification(run_b, ReplayOutcome::Rejected)
        .await
        .unwrap();
    for q in ["journey?period=all", "journey", "distance"] {
        let board = app.board_ok(None, q).await;
        assert_eq!(board["entries"][0]["run_id"], a["run_id"], "{q}");
    }
    let v: String = sqlx::query_scalar("SELECT verification FROM runs WHERE id = ?")
        .bind(run_b)
        .fetch_one(app.db())
        .await
        .unwrap();
    assert_eq!(v, "rejected");
}

#[tokio::test]
async fn daily_run_needs_the_dates_seed() {
    let app = runs_app().await;
    let (_, tok) = app.account().await;
    let r = app
        .submit_ok(&tok, daily_run("daily-001", T0_DATE, 8_000))
        .await;
    assert_eq!(r["verification"], "pending");
    let boards: Vec<(&str, &str)> = r["placements"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| (p["board"].as_str().unwrap(), p["period"].as_str().unwrap()))
        .collect();
    assert_eq!(boards, vec![("daily", T0_DATE), ("distance", "all")]);
    let b = app.board_ok(None, "daily").await;
    assert_eq!(b["period"], T0_DATE);
    assert_eq!(b["period_kind"], "day");
    assert_eq!(ranking(&b)[0].1, 8_000);
    // Yesterday's seed on today's date.
    let mut wrong = daily_run("daily-002", T0_DATE, 8_000);
    wrong["seed"] = daily_seed::daily_seed_for_date("2026-09-20")
        .unwrap()
        .to_string()
        .into();
    let r = app.submit_ok(&tok, wrong).await;
    assert_eq!(r["verification"], "rejected");
    assert_eq!(r["reason"], "daily_seed");
}

/// Every plausibility rule, one at a time, from a plausible base run.
#[tokio::test]
async fn every_plausibility_rejection() {
    let app = app_with(|c| {
        long_tokens(c);
        c.runs.min_build = 5;
        c.runs.supported_builds = vec!["5".into(), "7".into()];
    })
    .await;
    let (id, tok) = app.account().await;
    let base = || {
        let mut v = journey_run("", 50_000, 20_000.0);
        v["client_build"] = 7.into();
        v
    };
    type Mutate = Box<dyn Fn(&mut Value)>;
    let cases: Vec<(&str, Mutate)> = vec![
        (
            "build_unsupported",
            Box::new(|v| v["client_build"] = 4.into()),
        ),
        (
            "build_unsupported",
            Box::new(|v| v["client_build"] = 6.into()),
        ),
        ("date_window", Box::new(|v| v["date"] = "2026-09-19".into())),
        ("date_window", Box::new(|v| v["date"] = "2026-09-23".into())),
        ("duration", Box::new(|v| v["duration_s"] = 30_000.0.into())),
        ("duration", Box::new(|v| v["night_time_s"] = 401.0.into())),
        ("top_speed", Box::new(|v| v["top_speed_kmh"] = 400.0.into())),
        // 400 s at 100 km/h is 11.1 km (+5 % + 200 m).
        ("distance", Box::new(|v| v["top_speed_kmh"] = 100.0.into())),
        // Five legs need 15 km.
        ("distance", Box::new(|v| v["distance_m"] = 10_000.0.into())),
        (
            "score_rate",
            Box::new(|v| {
                v["duration_s"] = 60.0.into();
                v["distance_m"] = 4_000.0.into();
                v["legs_completed"] = 1.into();
                v["score"] = 250_000.into();
            }),
        ),
        ("stats", Box::new(|v| v["close_passes"] = 201.into())),
        ("stats", Box::new(|v| v["threads"] = 101.into())),
        ("stats", Box::new(|v| v["coast_reached"] = true.into())),
        ("stats", Box::new(|v| v["journey_complete"] = true.into())),
        ("stats", Box::new(|v| v["hits"] = 8.into())),
        ("stats", Box::new(|v| v["best_multiplier"] = 0.5.into())),
        // 1 + 150 + 3·50 + 5·10 + 20 = 371.
        ("stats", Box::new(|v| v["best_multiplier"] = 372.0.into())),
        // (1500 + 1500 + 500 + 300) × 20 × 2 × 2 + 140 + 6 × 18500 × 2 ≈ 526k (+1 %).
        ("stats", Box::new(|v| v["score"] = 540_000.into())),
        ("stats", Box::new(|v| v["best_chain"] = 310_000.into())),
    ];
    for (i, (reason, mutate)) in cases.iter().enumerate() {
        let mut v = base();
        v["idempotency_key"] = format!("reject-{i:04}").into();
        mutate(&mut v);
        let r = app.submit(&tok, v).await;
        assert_eq!(r.status, 201, "{reason}: {:?}", r.json);
        assert_eq!(r.json["verification"], "rejected", "case {i}");
        assert_eq!(r.json["reason"], *reason, "case {i}");
        assert_eq!(r.json["replay_required"], false);
        assert!(r.json["placements"].as_array().unwrap().is_empty());
    }
    // Rejected runs are kept (audit), never on a board.
    let rejected: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM runs WHERE account_id = ? AND verification = 'rejected'",
    )
    .bind(id)
    .fetch_one(app.db())
    .await
    .unwrap();
    assert_eq!(rejected, cases.len() as i64);
    let entries: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM leaderboard_entries")
        .fetch_one(app.db())
        .await
        .unwrap();
    assert_eq!(entries, 0);
    // The base run itself passes, and the window's edges hold: yesterday within the late
    // window, tomorrow within the early window.
    let mut ok = base();
    ok["idempotency_key"] = "accept-0001".into();
    assert_eq!(app.submit_ok(&tok, ok).await["verification"], "pending");
    app.clock.set(T0_MIDNIGHT + DAY - 10); // 2026-09-21 23:59:50 UTC
    let mut tomorrow = base();
    tomorrow["idempotency_key"] = "accept-0002".into();
    tomorrow["date"] = "2026-09-22".into();
    assert_ne!(
        app.submit_ok(&tok, tomorrow).await["verification"],
        "rejected"
    );
    app.clock.set(T0_MIDNIGHT + DAY + 6 * 3_600); // 06:00 the next day: the late window ends
    let mut late = base();
    late["idempotency_key"] = "accept-0003".into();
    late["date"] = T0_DATE.into();
    assert_eq!(app.submit_ok(&tok, late).await["reason"], "date_window");
}

#[tokio::test]
async fn malformed_submissions_are_400() {
    let app = runs_app().await;
    let (_, tok) = app.account().await;
    let cases: Vec<(&str, Value)> = vec![
        ("short key", {
            let mut v = journey_run("short", 1, 20_000.0);
            v["idempotency_key"] = "abc".into();
            v
        }),
        ("key chars", journey_run("has space!", 1, 20_000.0)),
        ("mode", {
            let mut v = journey_run("mode-0001", 1, 20_000.0);
            v["mode"] = "loop".into();
            v
        }),
        ("date", {
            let mut v = journey_run("date-0001", 1, 20_000.0);
            v["date"] = "2026-02-30".into();
            v
        }),
        ("car", {
            let mut v = journey_run("car-00001", 1, 20_000.0);
            v["car"] = "Coupe GT".into();
            v
        }),
        ("negative", {
            let mut v = journey_run("neg-00001", 1, 20_000.0);
            v["distance_m"] = (-1.0).into();
            v
        }),
        ("huge score", journey_run("huge-0001", 1 << 54, 20_000.0)),
        ("unknown field", {
            let mut v = journey_run("unk-00001", 1, 20_000.0);
            v["personal_best"] = 5.into();
            v
        }),
        ("missing field", {
            let mut v = journey_run("miss-0001", 1, 20_000.0);
            v.as_object_mut().unwrap().remove("hits");
            v
        }),
        ("seed text", {
            let mut v = journey_run("seed-0001", 1, 20_000.0);
            v["seed"] = "12ab".into();
            v
        }),
    ];
    for (what, body) in cases {
        let r = app.submit(&tok, body).await;
        assert_error(&r, 400, "invalid_body");
        assert!(!what.is_empty());
    }
    let r = app
        .call(
            "POST",
            "/api/v1/runs",
            None,
            Some(journey_run("noauth-01", 1, 1.0)),
        )
        .await;
    assert_error(&r, 401, "unauthorized");
}

#[tokio::test]
async fn submissions_are_rate_limited_per_account() {
    let app = app_with(|c| {
        long_tokens(c);
        c.rate_limits.runs_per_hour = 30;
        c.rate_limits.runs_burst = 3;
    })
    .await;
    let (_, tok) = app.account().await;
    for i in 0..3 {
        app.submit_ok(&tok, journey_run(&format!("limit-{i:04}"), 100, 20_000.0))
            .await;
    }
    let r = app
        .submit(&tok, journey_run("limit-0003", 100, 20_000.0))
        .await;
    assert_error(&r, 429, "rate_limited");
    assert!(r.json["retry_after_secs"].as_u64().unwrap() > 0);
    // Another account has its own bucket, and board reads are not submissions.
    let (_, other) = app.account().await;
    app.submit_ok(&other, journey_run("limit-0100", 100, 20_000.0))
        .await;
    app.board_ok(Some(&tok), "journey").await;
}

// ---------------------------------------------------------------------------------------------
// Legacy personal bests
// ---------------------------------------------------------------------------------------------

#[tokio::test]
async fn legacy_upload_once_per_board_marked_and_capped() {
    let app = runs_app().await;
    let (_, tok) = app.account().await;
    let up = |entries: Value| async {
        let entries = entries;
        app.call(
            "POST",
            "/api/v1/runs/legacy",
            Some(&tok),
            Some(json!({ "entries": entries })),
        )
        .await
    };
    let r = up(json!([
        {"board": "journey", "score": 77_000},
        {"board": "distance", "score": 3_000_000}
    ]))
    .await;
    assert_eq!(r.status, 200, "{:?}", r.json);
    assert_eq!(r.json["results"][0]["status"], "accepted");
    assert_eq!(r.json["results"][0]["placement"]["period"], "all");
    assert_eq!(r.json["results"][0]["placement"]["on_board"], true);
    // 3000 km is over the 2000 km cap: refused, not stored, may be retried.
    assert_eq!(r.json["results"][1]["status"], "over_cap");
    let r = up(json!([
        {"board": "distance", "score": 45_000},
        {"board": "journey", "score": 99_000}
    ]))
    .await;
    assert_eq!(r.json["results"][0]["status"], "accepted");
    assert_eq!(r.json["results"][1]["status"], "already_uploaded");
    let j = app.board_ok(None, "journey?period=all").await;
    assert_eq!(j["entries"][0]["score"], 77_000);
    assert_eq!(j["entries"][0]["legacy"], true);
    assert_eq!(j["entries"][0]["verification"], "legacy");
    let d = app.board_ok(None, "distance").await;
    assert_eq!(d["entries"][0]["score"], 45_000);
    assert_eq!(d["entries"][0]["legacy"], true);
    // Not on the weekly board.
    assert_eq!(app.board_ok(None, "journey").await["total"], 0);
    // A real run that beats the legacy best replaces it.
    app.submit_ok(&tok, journey_run("real-0001", 80_000, 20_000.0))
        .await;
    let j = app.board_ok(None, "journey?period=all").await;
    assert_eq!(j["entries"][0]["legacy"], false);
    // Malformed uploads.
    for bad in [
        json!([]),
        json!([{"board": "daily", "score": 5}]),
        json!([{"board": "loop", "score": 5}]),
        json!([{"board": "journey", "score": 0}]),
        json!([{"board": "journey", "score": 5}, {"board": "journey", "score": 6}]),
    ] {
        assert_error(&up(bad).await, 400, "invalid_body");
    }
}

// ---------------------------------------------------------------------------------------------
// Account deletion
// ---------------------------------------------------------------------------------------------

#[tokio::test]
async fn account_deletion_removes_runs_entries_and_replays() {
    let app = runs_app().await;
    let (gone, tok) = app.account().await;
    let (stays, other) = app.account().await;
    let r = app
        .submit_ok(&tok, journey_run("del-00001", 9_000, 20_000.0))
        .await;
    app.submit_ok(&tok, daily_run("del-00002", T0_DATE, 9_000))
        .await;
    app.submit_ok(&other, journey_run("del-00003", 5_000, 20_000.0))
        .await;
    let run_id: i64 = r["run_id"].as_str().unwrap().parse().unwrap();
    let replay = app.dir.path().join("replays").join(format!("{run_id}.bin"));
    std::fs::create_dir_all(replay.parent().unwrap()).unwrap();
    std::fs::write(&replay, b"replay").unwrap();
    sqlx::query(
        "INSERT INTO replays (run_id, file_path, status, created_at) VALUES (?, ?, 'queued', ?)",
    )
    .bind(run_id)
    .bind(replay.to_str().unwrap())
    .bind(T0)
    .execute(app.db())
    .await
    .unwrap();
    // Warm the cache, then delete.
    assert_eq!(app.board_ok(None, "journey?period=all").await["total"], 2);
    let r = app
        .call("DELETE", "/api/v1/account", Some(&tok), None)
        .await;
    assert_eq!(r.status, 204, "{:?}", r.json);
    for (table, sql) in [
        ("runs", "SELECT COUNT(*) FROM runs WHERE account_id = ?"),
        (
            "leaderboard_entries",
            "SELECT COUNT(*) FROM leaderboard_entries WHERE account_id = ?",
        ),
    ] {
        let n: i64 = sqlx::query_scalar(sql)
            .bind(gone)
            .fetch_one(app.db())
            .await
            .unwrap();
        assert_eq!(n, 0, "{table}");
    }
    let n: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM replays")
        .fetch_one(app.db())
        .await
        .unwrap();
    assert_eq!(n, 0);
    assert!(!replay.exists(), "replay file deleted");
    let j = app.board_ok(None, "journey?period=all").await;
    assert_eq!(ranking(&j), vec![(stays.to_string(), 5_000)]);
    assert_eq!(app.board_ok(None, "daily").await["total"], 0);
    let detail: String = sqlx::query_scalar(
        "SELECT detail FROM admin_log WHERE action = 'account_delete' AND target = ?",
    )
    .bind(gone.to_string())
    .fetch_one(app.db())
    .await
    .unwrap();
    assert!(
        detail.contains("runs=2")
            && detail.contains("leaderboard_entries=4")
            && detail.contains("replays=1"),
        "{detail}"
    );
}
