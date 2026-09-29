//! N1.1 rate limits: per IP on the auth routes (strict on device creation), per account
//! on authenticated routes, 429 + Retry-After in the API error format, and
//! `X-Forwarded-For` believed only from trusted proxies.
mod common;

use common::assert_error;
use serde_json::json;
use std::time::Duration;

const PUBLIC_A: &str = "203.0.113.7:5000";
const PUBLIC_B: &str = "203.0.113.8:5000";
const PROXY: &str = "10.0.1.5:44000";

async fn create_from(app: &common::TestApp, peer: &str, xff: Option<&str>) -> common::Resp {
    let headers: Vec<(&str, &str)> = xff.map(|v| ("x-forwarded-for", v)).into_iter().collect();
    app.raw("POST", "/api/v1/auth/device", peer, &headers, Vec::new())
        .await
}

fn strict(c: &mut westbound_server::Config) {
    c.rate_limits.device_create_per_hour = 5;
    c.rate_limits.device_create_burst = 2;
}

#[tokio::test]
async fn device_creation_is_limited_per_ip() {
    let app = common::app_with(strict).await;
    assert_eq!(create_from(&app, PUBLIC_A, None).await.status, 201);
    assert_eq!(create_from(&app, PUBLIC_A, None).await.status, 201);
    let r = create_from(&app, PUBLIC_A, None).await;
    assert_error(&r, 429, "rate_limited");
    let retry: u64 = r.headers["retry-after"].to_str().unwrap().parse().unwrap();
    // 5 per hour: the next slot is up to 12 minutes away.
    assert!((1..=721).contains(&retry), "{retry}");
    assert_eq!(r.json["retry_after_secs"], json!(retry));
    // Another IP has its own bucket.
    assert_eq!(create_from(&app, PUBLIC_B, None).await.status, 201);
    // The same IPv6 /64 shares one bucket.
    assert_eq!(
        create_from(&app, "[2001:db8:1:2::1]:1", None).await.status,
        201
    );
    assert_eq!(
        create_from(&app, "[2001:db8:1:2::2]:1", None).await.status,
        201
    );
    assert_eq!(
        create_from(&app, "[2001:db8:1:2::3]:1", None).await.status,
        429
    );
    assert_eq!(
        create_from(&app, "[2001:db8:1:3::1]:1", None).await.status,
        201
    );
    assert!(app
        .state
        .metrics
        .render("v", "b")
        .contains("wb_http_rate_limited_total 2"));
}

#[tokio::test]
async fn forwarded_for_is_trusted_only_from_proxies() {
    let app = common::app_with(strict).await;
    // Behind the proxy: the client is the right-most untrusted X-Forwarded-For hop.
    for _ in 0..2 {
        let r = create_from(&app, PROXY, Some("198.18.0.1, 203.0.113.7")).await;
        assert_eq!(r.status, 201);
    }
    assert_eq!(
        create_from(&app, PROXY, Some("203.0.113.7")).await.status,
        429,
        "same client as above"
    );
    // Proxy chains: trusted hops are skipped.
    assert_eq!(
        create_from(&app, PROXY, Some("203.0.113.7, 10.0.0.2"))
            .await
            .status,
        429
    );
    // A spoofed left-most entry does not help.
    assert_eq!(
        create_from(&app, PROXY, Some("1.1.1.1, 203.0.113.7"))
            .await
            .status,
        429
    );
    assert_eq!(
        create_from(&app, PROXY, Some("203.0.113.99")).await.status,
        201
    );
    // A direct (untrusted) client cannot pick its IP with the header.
    assert_eq!(
        create_from(&app, PUBLIC_B, Some("192.0.2.1")).await.status,
        201
    );
    assert_eq!(
        create_from(&app, PUBLIC_B, Some("192.0.2.2")).await.status,
        201
    );
    assert_eq!(
        create_from(&app, PUBLIC_B, Some("192.0.2.3")).await.status,
        429
    );

    // No trusted proxies: the header is ignored even from a private peer.
    let app = common::app_with(|c| {
        strict(c);
        c.http.trusted_proxies = Vec::new();
    })
    .await;
    assert_eq!(
        create_from(&app, PROXY, Some("192.0.2.1")).await.status,
        201
    );
    assert_eq!(
        create_from(&app, PROXY, Some("192.0.2.2")).await.status,
        201
    );
    assert_eq!(
        create_from(&app, PROXY, Some("192.0.2.3")).await.status,
        429
    );
}

#[tokio::test]
async fn auth_routes_are_limited_per_ip() {
    let app = common::app_with(|c| {
        c.rate_limits.auth_per_minute = 1;
        c.rate_limits.auth_burst = 3;
    })
    .await;
    let body = serde_json::to_vec(&json!({ "refresh_token": "x" })).unwrap();
    let h = [("content-type", "application/json")];
    for _ in 0..3 {
        let r = app
            .raw("POST", "/api/v1/auth/refresh", PUBLIC_A, &h, body.clone())
            .await;
        assert_eq!(r.status, 401);
    }
    let r = app
        .raw(
            "POST",
            "/api/v1/auth/device/login",
            PUBLIC_A,
            &h,
            body.clone(),
        )
        .await;
    assert_error(&r, 429, "rate_limited");
    let r = app
        .raw(
            "POST",
            "/api/v1/auth/link/apple",
            PUBLIC_A,
            &h,
            body.clone(),
        )
        .await;
    assert_eq!(r.status, 429);
    let r = app
        .raw("POST", "/api/v1/auth/refresh", PUBLIC_B, &h, body)
        .await;
    assert_eq!(r.status, 401);
}

#[tokio::test]
async fn authenticated_routes_are_limited_per_account() {
    let app = common::app_with(|c| {
        c.rate_limits.account_per_minute = 1;
        c.rate_limits.account_burst = 3;
    })
    .await;
    let a = app.create_device().await;
    let b = app.create_device().await;
    for _ in 0..3 {
        assert_eq!(app.me(&a.session.access_token).await.status, 200);
    }
    let r = app.me(&a.session.access_token).await;
    assert_error(&r, 429, "rate_limited");
    assert!(r.headers.contains_key("retry-after"));
    // Same IP, other account: its own bucket.
    assert_eq!(app.me(&b.session.access_token).await.status, 200);
    // A second session of account A shares A's bucket.
    let again = app.login(&a.session.account_id, &a.device_secret).await;
    let token = again.json["access_token"].as_str().unwrap();
    assert_eq!(app.me(token).await.status, 429);
}

#[tokio::test]
async fn real_server_answers_429_with_retry_after() {
    let s = common::start_with(strict).await;
    let req = format!(
        "POST /api/v1/auth/device HTTP/1.1\r\nHost: {}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        s.addr
    );
    // Loopback is a trusted proxy by default, without a header it is the client.
    for _ in 0..2 {
        let resp = common::raw_http(s.addr, &req).await;
        assert!(resp.starts_with("HTTP/1.1 201"), "{resp}");
    }
    let resp = common::raw_http(s.addr, &req).await;
    assert!(resp.starts_with("HTTP/1.1 429"), "{resp}");
    assert!(resp.to_ascii_lowercase().contains("retry-after:"), "{resp}");
    assert!(resp.contains("\"error\":\"rate_limited\""), "{resp}");
    tokio::time::timeout(Duration::from_secs(5), s.stop())
        .await
        .unwrap();
}
