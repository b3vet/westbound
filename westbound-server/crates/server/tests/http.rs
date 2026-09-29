//! HTTP surface: health, deep-link files, 404, metrics listener.
mod common;

use std::time::Duration;

use westbound_server::healthcheck;
use westbound_server::http::Health;

const T: Duration = Duration::from_secs(3);

#[tokio::test]
async fn health_reports_ok_with_db() {
    let s = common::start().await;
    let resp = healthcheck::get(s.addr, "/api/v1/health", T).await.unwrap();
    assert_eq!(resp.status, 200);
    let h: Health = serde_json::from_str(&resp.body).unwrap();
    assert_eq!(h.status, "ok");
    assert_eq!(h.db, "ok");
    assert_eq!(h.version, westbound_server::VERSION);
    assert_eq!(h.build, westbound_server::BUILD);
    // The healthcheck subcommand's probe agrees.
    let probed = healthcheck::check(s.addr, T).await.unwrap();
    assert_eq!(probed, h);
    s.stop().await;
}

#[tokio::test]
async fn health_degrades_when_db_is_gone() {
    let s = common::start().await;
    s.state.db.close().await;
    let resp = healthcheck::get(s.addr, "/api/v1/health", T).await.unwrap();
    assert_eq!(resp.status, 503);
    let h: Health = serde_json::from_str(&resp.body).unwrap();
    assert_eq!((h.status.as_str(), h.db.as_str()), ("degraded", "error"));
    assert!(healthcheck::check(s.addr, T).await.is_err());
    s.stop().await;
}

#[tokio::test]
async fn serves_deep_link_placeholders_and_404() {
    let s = common::start().await;
    let aasa = healthcheck::get(s.addr, "/.well-known/apple-app-site-association", T)
        .await
        .unwrap();
    assert_eq!(aasa.status, 200);
    let v: serde_json::Value = serde_json::from_str(&aasa.body).unwrap();
    assert!(v["applinks"]["details"].is_array());
    let al = healthcheck::get(s.addr, "/.well-known/assetlinks.json", T)
        .await
        .unwrap();
    assert_eq!(al.status, 200);
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&al.body).unwrap(),
        serde_json::json!([])
    );
    let page = healthcheck::get(s.addr, "/api/v1/echo-check", T)
        .await
        .unwrap();
    assert_eq!(page.status, 200);
    assert!(page.body.contains("new WebSocket(url)"));
    let missing = healthcheck::get(s.addr, "/nope", T).await.unwrap();
    assert_eq!(missing.status, 404);
    s.stop().await;
}

#[tokio::test]
async fn serves_deep_link_files_from_config_dir() {
    let links = tempfile::tempdir().unwrap();
    let body = r#"[{"relation":["delegate_permission/common.handle_all_urls"]}]"#;
    std::fs::write(links.path().join("assetlinks.json"), body).unwrap();
    let dir = links.path().to_path_buf();
    let s = common::start_with(move |c| c.deeplinks.dir = dir).await;
    let al = healthcheck::get(s.addr, "/.well-known/assetlinks.json", T)
        .await
        .unwrap();
    assert_eq!(al.body, body);
    // The other file is missing from the dir: placeholder.
    let aasa = healthcheck::get(s.addr, "/.well-known/apple-app-site-association", T)
        .await
        .unwrap();
    assert_eq!(aasa.status, 200);
    s.stop().await;
}

#[tokio::test]
async fn metrics_listener_counts_requests() {
    let s = common::start().await;
    healthcheck::get(s.addr, "/api/v1/health", T).await.unwrap();
    healthcheck::get(s.addr, "/nope", T).await.unwrap();
    let m = healthcheck::get(s.metrics_addr, "/metrics", T)
        .await
        .unwrap();
    assert_eq!(m.status, 200);
    assert!(
        m.body.contains("wb_http_requests_total{class=\"2xx\"} 1"),
        "{}",
        m.body
    );
    assert!(
        m.body.contains("wb_http_requests_total{class=\"4xx\"} 1"),
        "{}",
        m.body
    );
    assert!(m.body.contains("wb_ws_connections 0"));
    assert!(m.body.contains("wb_ws_frames_in_total 0"));
    // /metrics is not on the public listener.
    let public = healthcheck::get(s.addr, "/metrics", T).await.unwrap();
    assert_eq!(public.status, 404);
    s.stop().await;
}

fn preflight(addr: std::net::SocketAddr, origin: &str) -> String {
    format!(
        "OPTIONS /api/v1/health HTTP/1.1\r\nHost: {addr}\r\nOrigin: {origin}\r\n\
         Access-Control-Request-Method: GET\r\nConnection: close\r\n\r\n"
    )
}

#[tokio::test]
async fn cors_allows_the_web_build_and_production_origins_only() {
    let s = common::start().await;
    for origin in [
        "https://b3vet.github.io",
        "https://westbound.sipsakrandevu.com",
    ] {
        let resp = common::raw_http(s.addr, &preflight(s.addr, origin)).await;
        let expected = format!("access-control-allow-origin: {origin}");
        assert!(resp.to_ascii_lowercase().contains(&expected), "{resp}");
    }
    let resp = common::raw_http(s.addr, &preflight(s.addr, "https://evil.example")).await;
    assert!(
        !resp
            .to_ascii_lowercase()
            .contains("access-control-allow-origin"),
        "{resp}"
    );
    s.stop().await;
}

#[tokio::test]
async fn metrics_bind_rejects_public_address() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = common::test_config(&dir);
    c.metrics.bind = "0.0.0.0:9090".into();
    let err = c.validate().unwrap_err();
    assert!(err.to_string().contains("loopback"), "{err}");
}
