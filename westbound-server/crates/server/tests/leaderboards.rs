//! Leaderboards (N7.1): every board, period and view, ranking ties, around-me at the
//! edges, period rollover on the injectable clock, multiplayer runs and the crew board,
//! admin removals, the top-N cache, and a 100k-entry performance check.

mod common;

use std::time::{Duration, Instant};

use common::*;
use serde_json::json;
use westbound_server::admin;
use westbound_server::leaderboards::{
    store, Board, CrewSnapshot, MultiplayerRun, Period, PeriodKind, RoomKind, View,
};

/// 2026-09-27 (a Sunday, the last day of ISO week 2026-W39) at `hh:mm` UTC.
fn sunday(hh: i64, mm: i64) -> i64 {
    T0_MIDNIGHT + 6 * DAY + hh * 3_600 + mm * 60
}

fn mp_run(account_id: i64, score: u32, room: RoomKind, ended_at: i64) -> MultiplayerRun {
    MultiplayerRun {
        account_id,
        map_id: "loop_v1".into(),
        room,
        score,
        duration_s: 600.0,
        distance_m: 25_000.0,
        stats: json!({"passes": 10, "close_passes": 2, "trains": 1}),
        car: "coupe".into(),
        client_build: 1,
        ended_at,
        crew: None,
    }
}

/// Writes an entry directly (setup for ranking tests; bypasses the cache).
async fn put(app: &TestApp, board: &str, period: &str, account: i64, score: i64, at: i64) {
    sqlx::query(
        "INSERT INTO leaderboard_entries (board, period_key, subject_id, account_id, run_id,
                                          score, achieved_at, verification, run_date)
         VALUES (?, ?, ?, ?, NULL, ?, ?, 'verified', '2026-09-21')",
    )
    .bind(board)
    .bind(period)
    .bind(account)
    .bind(account)
    .bind(score)
    .bind(at)
    .execute(app.db())
    .await
    .unwrap();
}

#[tokio::test]
async fn every_board_period_and_view() {
    let app = runs_app().await;
    let (a, ta) = app.account().await;
    let (b, tb) = app.account().await;
    app.submit_ok(&ta, journey_run("every-0001", 30_000, 24_000.0))
        .await;
    app.submit_ok(&tb, journey_run("every-0002", 20_000, 26_000.0))
        .await;
    app.submit_ok(&ta, daily_run("every-0003", T0_DATE, 7_000))
        .await;
    app.state
        .boards
        .record_multiplayer_run(&mp_run(b, 9_000, RoomKind::Public, T0))
        .await
        .unwrap();
    let (sa, sb) = (a.to_string(), b.to_string());
    type Case<'a> = (&'a str, &'a str, Vec<(String, i64)>);
    let expect: Vec<Case> = vec![
        (
            "journey",
            "2026-W39",
            vec![(sa.clone(), 30_000), (sb.clone(), 20_000)],
        ),
        (
            "journey?period=current",
            "2026-W39",
            vec![(sa.clone(), 30_000), (sb.clone(), 20_000)],
        ),
        (
            "journey?period=2026-W39",
            "2026-W39",
            vec![(sa.clone(), 30_000), (sb.clone(), 20_000)],
        ),
        (
            "journey?period=all",
            "all",
            vec![(sa.clone(), 30_000), (sb.clone(), 20_000)],
        ),
        ("journey?period=2026-W38", "2026-W38", vec![]),
        ("daily", T0_DATE, vec![(sa.clone(), 7_000)]),
        ("daily?period=2026-09-20", "2026-09-20", vec![]),
        (
            "distance",
            "all",
            vec![(sb.clone(), 26_000), (sa.clone(), 24_000)],
        ),
        ("loop", "2026-09", vec![(sb.clone(), 9_000)]),
        ("loop?period=all", "all", vec![(sb.clone(), 9_000)]),
        ("loop?period=2026-08", "2026-08", vec![]),
        ("loop_crew", "2026-09", vec![]),
    ];
    for (q, period, want) in expect {
        let body = app.board_ok(None, q).await;
        assert_eq!(body["period"], period, "{q}");
        assert_eq!(ranking(&body), want, "{q}");
        assert_eq!(body["total"], want.len(), "{q}");
        assert_eq!(body["view"], "global");
        assert!(body["me"].is_null(), "{q}: no token, no me");
    }
    // Global with a token adds `me`; limit trims.
    let body = app.board_ok(Some(&tb), "journey?limit=1").await;
    assert_eq!(ranking(&body), vec![(sa.clone(), 30_000)]);
    assert_eq!(body["me"]["account_id"], sb);
    assert_eq!(body["me"]["rank"], 2);
    // Around me.
    let body = app.board_ok(Some(&tb), "distance?view=around_me").await;
    assert_eq!(ranks(&body), vec![1, 2]);
    assert_eq!(body["view"], "around_me");
    // Friends: not available until N9.
    let body = app.board_ok(Some(&ta), "journey?view=friends").await;
    assert_eq!(body["friends_available"], false);
    assert!(body["entries"].as_array().unwrap().is_empty());
    assert_eq!(body["me"]["rank"], 1);
    // The crew board: no crew for the caller yet.
    let body = app.board_ok(Some(&ta), "loop_crew?view=around_me").await;
    assert!(body["entries"].as_array().unwrap().is_empty());
    assert!(body["me"].is_null());
    // Errors.
    assert_error(
        &app.board(None, "journey?view=around_me").await,
        401,
        "unauthorized",
    );
    assert_error(
        &app.board(None, "journey?view=friends").await,
        401,
        "unauthorized",
    );
    assert_error(
        &app.board(None, "journey?view=everyone").await,
        400,
        "invalid_view",
    );
    assert_error(&app.board(None, "nope").await, 404, "unknown_board");
    for bad_period in [
        "journey?period=2026-09",
        "journey?period=2026-W54",
        "daily?period=all",
        "loop_crew?period=all",
        "distance?period=2026-W39",
        "loop?period=2026-9",
    ] {
        assert_error(&app.board(None, bad_period).await, 400, "invalid_period");
    }
    for bad_limit in ["journey?limit=0", "journey?limit=101", "journey?limit=x"] {
        assert_error(&app.board(None, bad_limit).await, 400, "invalid_limit");
    }
    assert_error(
        &app.board(Some(&ta), "journey?view=around_me&limit=51")
            .await,
        400,
        "invalid_limit",
    );
    assert_error(
        &app.board(None, "journey?sort=asc").await,
        400,
        "invalid_query",
    );
    assert_error(
        &app.board(None, "journey?limit=1&limit=2").await,
        400,
        "invalid_query",
    );
    assert_error(
        &app.board(Some("bad.token"), "journey").await,
        401,
        "invalid_token",
    );
}

#[tokio::test]
async fn ties_rank_the_earlier_run_first() {
    let app = runs_app().await;
    let (a, ta) = app.account().await;
    let (b, tb) = app.account().await;
    let (c, tc) = app.account().await;
    // b submits first, then a (10 s later), then c: equal scores rank b, a, c.
    app.submit_ok(&tb, journey_run("tie-00001", 10_000, 20_000.0))
        .await;
    app.clock.advance(10);
    app.submit_ok(&ta, journey_run("tie-00002", 10_000, 20_000.0))
        .await;
    app.clock.advance(10);
    let r = app
        .submit_ok(&tc, journey_run("tie-00003", 10_000, 20_000.0))
        .await;
    assert_eq!(r["placements"][0]["rank"], 3);
    let body = app.board_ok(Some(&tc), "journey").await;
    let order: Vec<String> = ranking(&body).into_iter().map(|e| e.0).collect();
    assert_eq!(order, vec![b.to_string(), a.to_string(), c.to_string()]);
    assert_eq!(ranks(&body), vec![1, 2, 3]);
    assert_eq!(body["me"]["rank"], 3);
    // Same score and same time: the lower id first.
    for id in [c, a, b] {
        put(&app, "journey", "2026-W10", id, 500, T0).await;
    }
    let body = app.board_ok(None, "journey?period=2026-W10").await;
    let order: Vec<String> = ranking(&body).into_iter().map(|e| e.0).collect();
    let mut ids = [a, b, c];
    ids.sort();
    assert_eq!(order, ids.iter().map(|i| i.to_string()).collect::<Vec<_>>());
}

#[tokio::test]
async fn around_me_at_the_edges() {
    let app = runs_app().await;
    let mut accounts = Vec::new();
    for i in 0..30i64 {
        let (id, tok) = app.account().await;
        // Distinct scores: account i ranks i + 1.
        put(&app, "journey", "all", id, 10_000 - i * 10, T0).await;
        accounts.push((id, tok));
    }
    let window = |rank: usize, limit: u32| {
        let tok = accounts[rank - 1].1.clone();
        let app = &app;
        async move {
            let body = app
                .board_ok(
                    Some(&tok),
                    &format!("journey?period=all&view=around_me&limit={limit}"),
                )
                .await;
            assert_eq!(body["me"]["rank"], rank as u64);
            ranks(&body)
        }
    };
    let span = |a: u64, b: u64| (a..=b).collect::<Vec<u64>>();
    assert_eq!(window(1, 3).await, span(1, 7), "top: shifted down");
    assert_eq!(window(2, 3).await, span(1, 7));
    assert_eq!(window(4, 3).await, span(1, 7), "exactly centred");
    assert_eq!(window(15, 3).await, span(12, 18));
    assert_eq!(window(29, 3).await, span(24, 30));
    assert_eq!(window(30, 3).await, span(24, 30), "bottom: shifted up");
    assert_eq!(
        window(15, 20).await,
        span(1, 30),
        "window larger than the board"
    );
    assert_eq!(window(1, 1).await, span(1, 3));
    // Default limit (10 each side).
    let body = app
        .board_ok(Some(&accounts[14].1), "journey?period=all&view=around_me")
        .await;
    assert_eq!(ranks(&body), span(5, 25));
    // Entries carry the right people around me.
    let ids: Vec<String> = ranking(&body).into_iter().map(|e| e.0).collect();
    assert_eq!(ids[10], accounts[14].0.to_string());
    // Ties inside the window are walked in rank order too.
    let (x, tx) = app.account().await;
    put(&app, "journey", "all", x, 10_000 - 14 * 10, T0 + 1).await; // ties rank 15, later
    let body = app
        .board_ok(Some(&tx), "journey?period=all&view=around_me&limit=2")
        .await;
    assert_eq!(body["me"]["rank"], 16);
    assert_eq!(ranks(&body), span(14, 18));
    assert_eq!(body["entries"][1]["account_id"], accounts[14].0.to_string());
    // No entry: nothing around.
    let (_, none) = app.account().await;
    let body = app
        .board_ok(Some(&none), "journey?period=all&view=around_me")
        .await;
    assert!(body["me"].is_null());
    assert!(body["entries"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn periods_roll_over_on_the_clock() {
    let app = runs_app().await;
    let (a, ta) = app.account().await;
    // Week: Sunday 23:00 is still 2026-W39.
    app.clock.set(sunday(23, 0));
    let mut run = journey_run("roll-0001", 11_000, 20_000.0);
    run["date"] = "2026-09-27".into();
    app.submit_ok(&ta, run).await;
    assert_eq!(app.board_ok(None, "journey").await["period"], "2026-W39");
    assert_eq!(app.board_ok(None, "daily").await["period"], "2026-09-27");
    // Monday 00:30: a new week (empty) and a new day.
    app.clock.set(sunday(24, 30));
    let body = app.board_ok(None, "journey").await;
    assert_eq!(body["period"], "2026-W40");
    assert_eq!(body["total"], 0);
    assert_eq!(app.board_ok(None, "daily").await["period"], "2026-09-28");
    assert_eq!(
        app.board_ok(None, "journey?period=2026-W39").await["total"],
        1
    );
    // A run dated Sunday, sent just after midnight (inside the late window), still goes
    // to Sunday's week; a Monday run starts the new week.
    let (_, tb) = app.account().await;
    let mut late = journey_run("roll-0002", 12_000, 20_000.0);
    late["date"] = "2026-09-27".into();
    let r = app.submit_ok(&tb, late).await;
    assert_eq!(r["placements"][0]["period"], "2026-W39");
    let mut monday = journey_run("roll-0003", 5_000, 20_000.0);
    monday["date"] = "2026-09-28".into();
    let r = app.submit_ok(&ta, monday).await;
    assert_eq!(r["placements"][0]["period"], "2026-W40");
    assert_eq!(r["placements"][0]["rank"], 1);
    let body = app.board_ok(None, "journey").await;
    assert_eq!(ranking(&body), vec![(a.to_string(), 5_000)]);
    assert_eq!(
        app.board_ok(None, "journey?period=2026-W39").await["total"],
        2
    );
    // Season: Loop's current season follows the clock's month.
    let sep_last = T0_MIDNIGHT + 9 * DAY + DAY - 60; // 2026-09-30 23:59
    app.clock.set(sep_last);
    let boards = &app.state.boards;
    boards
        .record_multiplayer_run(&mp_run(a, 4_000, RoomKind::Public, sep_last))
        .await
        .unwrap();
    assert_eq!(app.board_ok(None, "loop").await["period"], "2026-09");
    app.clock.set(sep_last + 120); // 2026-10-01 00:01
    let body = app.board_ok(None, "loop").await;
    assert_eq!(body["period"], "2026-10");
    assert_eq!(body["total"], 0);
    let r = boards
        .record_multiplayer_run(&mp_run(a, 3_000, RoomKind::Public, sep_last + 120))
        .await
        .unwrap();
    assert_eq!(r.placements[0].period, "2026-10");
    assert!(r.placements[0].improved);
    assert!(
        !r.placements[1].improved,
        "all-time keeps the better September run"
    );
    assert_eq!(ranking(&app.board_ok(None, "loop").await)[0].1, 3_000);
    assert_eq!(
        ranking(&app.board_ok(None, "loop?period=2026-09").await)[0].1,
        4_000
    );
    assert_eq!(
        ranking(&app.board_ok(None, "loop?period=all").await)[0].1,
        4_000
    );
    assert_eq!(
        app.board_ok(None, "loop_crew").await["period"],
        "2026-10",
        "the crew board's season rolls over too"
    );
}

#[tokio::test]
async fn multiplayer_runs_rooms_and_crews() {
    let app = runs_app().await;
    let boards = app.state.boards.clone();
    let mut ids = Vec::new();
    for _ in 0..5 {
        ids.push(app.account().await.0);
    }
    // Public and default private rooms rank; custom private rooms only keep the run.
    let r = boards
        .record_multiplayer_run(&mp_run(ids[0], 100, RoomKind::Public, T0))
        .await
        .unwrap();
    assert!(r.ranked);
    let periods: Vec<(&str, &str)> = r
        .placements
        .iter()
        .map(|p| (p.board.as_str(), p.period.as_str()))
        .collect();
    assert_eq!(periods, vec![("loop", "2026-09"), ("loop", "all")]);
    let r = boards
        .record_multiplayer_run(&mp_run(ids[1], 200, RoomKind::PrivateDefault, T0))
        .await
        .unwrap();
    assert!(r.ranked && r.placements.iter().all(|p| p.on_board));
    let r = boards
        .record_multiplayer_run(&mp_run(ids[2], 999_999, RoomKind::PrivateCustom, T0))
        .await
        .unwrap();
    assert!(!r.ranked && r.placements.is_empty());
    let row: (String, String, String) =
        sqlx::query_as("SELECT verification, room_type, map_or_seed FROM runs WHERE id = ?")
            .bind(r.run_id)
            .fetch_one(app.db())
            .await
            .unwrap();
    assert_eq!(
        row,
        ("verified".into(), "private_custom".into(), "loop_v1".into())
    );
    let body = app.board_ok(None, "loop").await;
    assert_eq!(
        ranking(&body),
        vec![(ids[1].to_string(), 200), (ids[0].to_string(), 100)]
    );
    assert_eq!(body["entries"][0]["verification"], "verified");
    // Crew: the sum of the best 4 members' season bests.
    for (i, score) in [(2usize, 300u32), (3, 400)] {
        boards
            .record_multiplayer_run(&mp_run(ids[i], score, RoomKind::Public, T0))
            .await
            .unwrap();
    }
    let crew = CrewSnapshot {
        crew_id: 77,
        member_ids: ids.clone(),
    };
    let mut run = mp_run(ids[4], 500, RoomKind::Public, T0 + 5);
    run.crew = Some(crew.clone());
    let r = boards.record_multiplayer_run(&run).await.unwrap();
    assert_eq!(r.crew_score, Some(500 + 400 + 300 + 200));
    let body = app.board_ok(None, "loop_crew").await;
    assert_eq!(body["entries"][0]["crew_id"], "77");
    assert!(body["entries"][0]["account_id"].is_null());
    assert_eq!(body["entries"][0]["score"], 1_400);
    // A worse run leaves the sum alone; a better one raises it.
    let mut run = mp_run(ids[0], 50, RoomKind::Public, T0 + 6);
    run.crew = Some(crew.clone());
    assert_eq!(
        boards
            .record_multiplayer_run(&run)
            .await
            .unwrap()
            .crew_score,
        None
    );
    let mut run = mp_run(ids[0], 450, RoomKind::Public, T0 + 7);
    run.crew = Some(crew);
    assert_eq!(
        boards
            .record_multiplayer_run(&run)
            .await
            .unwrap()
            .crew_score,
        Some(500 + 450 + 400 + 300)
    );
}

#[tokio::test]
async fn admin_removes_runs_and_entries() {
    let app = runs_app().await;
    let (a, ta) = app.account().await;
    let (b, tb) = app.account().await;
    let low = app
        .submit_ok(&ta, journey_run("adm-00001", 4_000, 20_000.0))
        .await;
    let high = app
        .submit_ok(&ta, journey_run("adm-00002", 8_000, 21_000.0))
        .await;
    app.submit_ok(&tb, journey_run("adm-00003", 6_000, 20_500.0))
        .await;
    let cfg = app.state.config.leaderboards.clone();
    let high_id: i64 = high["run_id"].as_str().unwrap().parse().unwrap();
    let msg = admin::remove_run(app.db(), &cfg, high_id).await.unwrap();
    assert!(msg.contains("journey/all"), "{msg}");
    // The CLI is another process: the server's cache catches up after its TTL.
    app.clock.advance(cfg.cache_ttl_secs as i64);
    let body = app.board_ok(None, "journey?period=all").await;
    assert_eq!(
        ranking(&body),
        vec![(b.to_string(), 6_000), (a.to_string(), 4_000)]
    );
    assert_eq!(body["entries"][1]["run_id"], low["run_id"]);
    assert_eq!(
        ranking(&app.board_ok(None, "distance").await)[0],
        (b.to_string(), 20_500)
    );
    assert!(admin::remove_run(app.db(), &cfg, high_id).await.is_err());
    // Remove an entry: gone, not rebuilt.
    let msg = admin::remove_entry(app.db(), "journey", "all", b)
        .await
        .unwrap();
    assert!(msg.contains("journey/all"), "{msg}");
    app.clock.advance(cfg.cache_ttl_secs as i64);
    let body = app.board_ok(None, "journey?period=all").await;
    assert_eq!(ranking(&body), vec![(a.to_string(), 4_000)]);
    assert!(admin::remove_entry(app.db(), "journey", "all", b)
        .await
        .is_err());
    assert!(admin::remove_entry(app.db(), "nope", "all", b)
        .await
        .is_err());
    assert!(admin::remove_entry(app.db(), "daily", "all", b)
        .await
        .is_err());
    let logged: Vec<(String, String)> = sqlx::query_as(
        "SELECT action, target FROM admin_log WHERE action IN ('remove_run', 'remove_entry')
         ORDER BY id",
    )
    .fetch_all(app.db())
    .await
    .unwrap();
    assert_eq!(
        logged,
        vec![
            ("remove_run".into(), high_id.to_string()),
            ("remove_entry".into(), format!("journey/all/{b}"))
        ]
    );
}

#[tokio::test]
async fn cache_invalidates_on_writes_and_expires() {
    let app = runs_app().await;
    let (a, ta) = app.account().await;
    let (b, _) = app.account().await;
    app.submit_ok(&ta, journey_run("cache-001", 1_000, 20_000.0))
        .await;
    assert_eq!(app.board_ok(None, "journey").await["total"], 1);
    assert_eq!(app.state.boards.cached_boards(), 1);
    // A write behind the cache's back (another process) is not seen until the TTL...
    put(&app, "journey", "2026-W39", b, 5_000, T0).await;
    assert_eq!(app.board_ok(None, "journey").await["total"], 1);
    let ttl = app.state.config.leaderboards.cache_ttl_secs as i64;
    app.clock.advance(ttl - 1);
    assert_eq!(app.board_ok(None, "journey").await["total"], 1);
    app.clock.advance(1);
    assert_eq!(app.board_ok(None, "journey").await["total"], 2);
    // ...while a write through the API shows at once.
    app.submit_ok(&ta, journey_run("cache-002", 9_000, 20_000.0))
        .await;
    let body = app.board_ok(None, "journey").await;
    assert_eq!(ranking(&body)[0], (a.to_string(), 9_000));
    // A rename drops the cached names.
    let r = app.rename(&ta, "Cached Name").await;
    assert_eq!(r.status, 200, "{:?}", r.json);
    let body = app.board_ok(None, "journey").await;
    assert_eq!(body["entries"][0]["display_name"], "Cached Name");
}

/// 100k entries on one board: top 100 and around-me stay within a few milliseconds.
#[tokio::test]
async fn performance_100k_entries() {
    const N: i64 = 100_000;
    let app = runs_app().await;
    let (me, tok) = app.account().await;
    let db = app.db();
    let t = Instant::now();
    let mut tx = db.begin().await.unwrap();
    sqlx::query(
        "WITH RECURSIVE c(x) AS (SELECT 0 UNION ALL SELECT x + 1 FROM c WHERE x < ?)
         INSERT INTO accounts (display_name, tag, created_at, last_seen)
         SELECT 'Bulk' || (x / 10000), x % 10000, 0, 0 FROM c",
    )
    .bind(N - 1)
    .execute(&mut *tx)
    .await
    .unwrap();
    // Scores with plenty of ties (0..50k), times spread out.
    sqlx::query(
        "INSERT INTO leaderboard_entries (board, period_key, subject_id, account_id, run_id,
                                          score, achieved_at, verification, run_date)
         SELECT 'journey', 'all', id, id, NULL, (id * 7919) % 50000, id % 997, 'verified',
                '2026-09-21'
         FROM accounts WHERE display_name LIKE 'Bulk%'",
    )
    .execute(&mut *tx)
    .await
    .unwrap();
    tx.commit().await.unwrap();
    sqlx::query("ANALYZE").execute(db).await.unwrap();
    eprintln!("perf: setup {:?}", t.elapsed());

    let period = Period::parse(PeriodKind::All, "all").unwrap();
    let boards = &app.state.boards;
    let mut conn = db.acquire().await.unwrap();

    // Top 100 straight from the database (a cache miss).
    let mut top_db = Duration::MAX;
    for _ in 0..5 {
        let t = Instant::now();
        let rows = store::top(&mut conn, "journey", "all", 100).await.unwrap();
        top_db = top_db.min(t.elapsed());
        assert_eq!(rows.len(), 100);
    }
    // The global view from the cache.
    boards
        .read(Board::Journey, &period, View::Global, 100, None)
        .await
        .unwrap();
    let mut top_cached = Duration::MAX;
    for _ in 0..5 {
        let t = Instant::now();
        let v = boards
            .read(Board::Journey, &period, View::Global, 100, None)
            .await
            .unwrap();
        top_cached = top_cached.min(t.elapsed());
        assert_eq!(v.entries.len(), 100);
        assert_eq!(v.total, N);
    }
    // Around me in the middle and near the bottom (rank computed by counting).
    let mut around = Vec::new();
    // Middle: score 25 000 (rank ~50 000). Bottom: score 50 (about 100 entries behind).
    for score in [25_000, 50] {
        sqlx::query(
            "INSERT OR REPLACE INTO leaderboard_entries
                 (board, period_key, subject_id, account_id, run_id, score, achieved_at,
                  verification, run_date)
             VALUES ('journey', 'all', ?, ?, NULL, ?, 500, 'verified', '2026-09-21')",
        )
        .bind(me)
        .bind(me)
        .bind(score)
        .execute(db)
        .await
        .unwrap();
        let mut best = Duration::MAX;
        let mut rank = 0;
        for _ in 0..5 {
            let t = Instant::now();
            let v = boards
                .read(Board::Journey, &period, View::AroundMe, 10, Some(me))
                .await
                .unwrap();
            best = best.min(t.elapsed());
            assert_eq!(v.entries.len(), 21);
            rank = v.me.unwrap().rank;
            let r: Vec<u64> = v.entries.iter().map(|e| e.rank).collect();
            assert_eq!(r, (rank - 10..=rank + 10).collect::<Vec<_>>());
        }
        around.push((rank, best));
    }
    // The counted rank agrees with a full sort.
    let sorted_rank: i64 = sqlx::query_scalar(
        "SELECT r FROM (SELECT subject_id, ROW_NUMBER() OVER
                           (ORDER BY score DESC, achieved_at, subject_id) AS r
                        FROM leaderboard_entries WHERE board = 'journey' AND period_key = 'all')
         WHERE subject_id = ?",
    )
    .bind(me)
    .fetch_one(db)
    .await
    .unwrap();
    assert_eq!(around[1].0 as i64, sorted_rank);
    eprintln!(
        "perf: {N} entries: top-100 from the db {top_db:?}, from the cache {top_cached:?}, \
         around-me at rank {} {:?}, at rank {} {:?}",
        around[0].0, around[0].1, around[1].0, around[1].1
    );
    // Regression guards. Measured (release, a busy 4-core box): top-100 0.4 ms from the
    // db, 0.03 ms cached; around-me 2.5 ms at rank 50k, 4.3 ms at rank 100k. Debug builds
    // (unoptimised SQLite) run about 4× slower.
    let budget = if cfg!(debug_assertions) {
        Duration::from_millis(100)
    } else {
        Duration::from_millis(10)
    };
    assert!(top_db < budget, "top-100 {top_db:?}");
    assert!(top_cached < budget, "cached top-100 {top_cached:?}");
    for (rank, d) in &around {
        assert!(*d < budget, "around me at rank {rank}: {d:?}");
    }
    // The HTTP path works on the big board too.
    let body = app
        .board_ok(Some(&tok), "journey?period=all&view=around_me&limit=2")
        .await;
    assert_eq!(body["entries"].as_array().unwrap().len(), 5);
}
