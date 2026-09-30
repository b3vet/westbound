//! N10.1: the admin stats view and the shadow contacts' table. Spec:
//! WESTBOUND_MULTIPLAYER_HANDOFF.md → Players (shadow collision logging: aggregates in the
//! admin stats), Data model (`shadow_contacts`), Resource budget (the numbers the view
//! reports against). Runbook: docs/SERVER.md → "Admin stats".

mod common;

use std::sync::Arc;

use protocol::AccountId;
use serde_json::Value;
use westbound_server::rooms::metrics::RoomMetrics;
use westbound_server::rooms::shadow_log;
use westbound_server::rooms::ShadowRow;

const REQ: &str = "GET /admin/stats HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";

fn body(resp: &str) -> Value {
    let (_, b) = resp.split_once("\r\n\r\n").expect("an HTTP response");
    serde_json::from_str(b).expect("JSON")
}

#[tokio::test]
async fn admin_stats_are_served_on_the_metrics_listener_only() {
    let s = common::start().await;
    let resp = common::raw_http(s.metrics_addr, REQ).await;
    assert!(resp.starts_with("HTTP/1.1 200"), "{resp}");
    let v = body(&resp);
    for key in ["process", "gateway", "rooms", "netcode", "shadow"] {
        assert!(v[key].is_object(), "{key}: {v}");
    }
    assert!(v["process"]["rss_mb"].as_f64().unwrap() > 1.0);
    assert!(v["process"]["cpu_seconds"].as_f64().unwrap() >= 0.0);
    assert_eq!(v["rooms"]["rooms"], 0);
    assert!(v["shadow"]["disagreement_m"].as_array().unwrap().len() == 9);
    // The database summaries are there (empty).
    assert_eq!(v["shadow"]["last_day"]["contacts"], 0);
    // Not on the public listener.
    let public = common::raw_http(s.addr, REQ).await;
    assert!(public.starts_with("HTTP/1.1 404"), "{public}");
    // The process numbers are on /metrics too.
    let m = common::raw_http(
        s.metrics_addr,
        "GET /metrics HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    )
    .await;
    assert!(m.contains("process_cpu_seconds_total "), "{m}");
    assert!(m.contains("process_resident_memory_bytes "));
    assert!(m.contains("wb_room_tick_max_seconds "));
    assert!(m.contains("wb_room_shadow_contact_disagreement_meters_count 0"));
    s.stop().await;
}

fn row(a: u64, b: u64, disagreement_m: f64, at: i64) -> ShadowRow {
    ShadowRow {
        room_id: 3,
        tick: 1_234,
        account_a: AccountId(a),
        account_b: AccountId(b),
        speed_mps: 50.0,
        disagreement_m,
        closing_mps: 2.0,
        depth_m: 0.8,
        ticks: 6,
        at,
    }
}

#[tokio::test]
async fn shadow_contacts_are_written_and_summarised() {
    let s = common::start().await;
    let db = &s.state.db;
    let now = westbound_server::rooms::unix_now_ms() / 1_000;
    shadow_log::insert(db, &row(7, 5, 0.2, now)).await.unwrap();
    shadow_log::insert(db, &row(5, 7, 1.5, now)).await.unwrap();
    shadow_log::insert(db, &row(9, 5, 0.4, now - 3 * 86_400))
        .await
        .unwrap();
    let day = shadow_log::summary(db, now - 86_400).await.unwrap();
    assert_eq!(day.contacts, 2);
    assert_eq!(day.pairs, 1, "accounts are stored ordered: one pair");
    assert_eq!(day.over_1m, 1);
    assert!((day.mean_disagreement_m - 0.85).abs() < 1e-9);
    assert!((day.max_disagreement_m - 1.5).abs() < 1e-9);
    assert!((day.mean_speed_kmh - 180.0).abs() < 1e-9);
    assert!((day.mean_ticks - 6.0).abs() < 1e-9);
    let week = shadow_log::summary(db, now - 7 * 86_400).await.unwrap();
    assert_eq!((week.contacts, week.pairs), (3, 2));
    let (a, b): (i64, i64) =
        sqlx::query_as("SELECT player_a, player_b FROM shadow_contacts ORDER BY id LIMIT 1")
            .fetch_one(db)
            .await
            .unwrap();
    assert_eq!((a, b), (5, 7));

    // The sink the app installs writes off the caller and counts.
    let metrics = Arc::new(RoomMetrics::default());
    let sink = shadow_log::db_sink(db.clone(), metrics.clone());
    for _ in 0..3 {
        sink(row(1, 2, 0.1, now));
    }
    common::eventually("the sink's rows", || {
        RoomMetrics::get(&metrics.shadow_rows_written) == 3
    })
    .await;
    assert_eq!(RoomMetrics::get(&metrics.shadow_rows_dropped), 0);
    let v = body(&common::raw_http(s.metrics_addr, REQ).await);
    assert_eq!(v["shadow"]["last_day"]["contacts"], 5);
    assert_eq!(v["shadow"]["last_week"]["contacts"], 6);
    s.stop().await;
}
