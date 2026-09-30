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
    assert!(page.body.contains("'/ws/echo'") && page.body.contains("'/ws'"));
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

/// N9.3: `/r/<code>` answers the invite page; the button opens the web build with
/// `?room=<code>` (normalized), store links say "coming soon" until configured; an invalid
/// code is a 404 page.
#[tokio::test]
async fn invite_links_serve_the_join_page() {
    let s = common::start().await;
    let page = healthcheck::get(s.addr, "/r/abc-234", T).await.unwrap();
    assert_eq!(page.status, 200);
    assert!(
        page.body
            .contains(r#"href="https://b3vet.github.io/westbound/?room=ABC234""#),
        "{}",
        page.body
    );
    assert!(page.body.contains("JOIN <b>ABC234</b>"));
    assert!(page.body.contains("APP STORE · COMING SOON"));
    assert!(page.body.contains("GOOGLE PLAY · COMING SOON"));
    assert!(!page.body.contains("OPEN THE APP"), "no scheme configured");
    // O, 0, I, 1 and L are not in codes; too short or too long either.
    for bad in ["/r/ABC0O1", "/r/ABC23", "/r/ABC2345", "/r/%3Cscript%3E"] {
        let p = healthcheck::get(s.addr, bad, T).await.unwrap();
        assert_eq!(p.status, 404, "{bad}");
        assert!(p.body.contains("INVITE NOT FOUND"));
        assert!(!p.body.contains("<script>"));
    }
    s.stop().await;
}

/// N9.3: with app ids in `[deeplinks]` the association files are generated (Universal
/// Links and App Links claim `/r/*`); the page gets the store links, the app scheme and
/// the web URL with `{origin}`.
#[tokio::test]
async fn deep_link_files_come_from_the_configured_app_ids() {
    let fp = ["AB"; 32].join(":");
    let fp2 = fp.clone();
    let s = common::start_with(move |c| {
        c.server.public_origin = "https://westbound.example".into();
        let d = &mut c.deeplinks;
        d.apple_app_ids = vec!["ABCDE12345.com.example.westbound".into()];
        d.android_package = "com.example.westbound".into();
        d.android_cert_sha256 = vec![fp2];
        d.app_store_url = "https://apps.apple.com/app/id1".into();
        d.play_store_url = "https://play.google.com/store/apps/details?id=x&hl=en".into();
        d.app_scheme = "westbound".into();
        d.web_join_url = "http://127.0.0.1:8000/index.html?room={code}&server={origin}".into();
    })
    .await;
    let aasa = healthcheck::get(s.addr, "/.well-known/apple-app-site-association", T)
        .await
        .unwrap();
    let v: serde_json::Value = serde_json::from_str(&aasa.body).unwrap();
    let d = &v["applinks"]["details"];
    assert_eq!(d[0]["appIDs"][0], "ABCDE12345.com.example.westbound");
    assert_eq!(d[0]["components"][0]["/"], "/r/*");
    assert_eq!(d[1]["appID"], "ABCDE12345.com.example.westbound");
    assert_eq!(d[1]["paths"][0], "/r/*");
    let al = healthcheck::get(s.addr, "/.well-known/assetlinks.json", T)
        .await
        .unwrap();
    let v: serde_json::Value = serde_json::from_str(&al.body).unwrap();
    assert_eq!(v[0]["target"]["package_name"], "com.example.westbound");
    assert_eq!(v[0]["target"]["sha256_cert_fingerprints"][0], fp.as_str());
    assert_eq!(
        v[0]["relation"][0],
        "delegate_permission/common.handle_all_urls"
    );
    let page = healthcheck::get(s.addr, "/r/K7QX2M", T).await.unwrap();
    assert!(page.body.contains(
        r#"href="http://127.0.0.1:8000/index.html?room=K7QX2M&amp;server=https://westbound.example""#
    ));
    assert!(page.body.contains(r#"href="westbound://r/K7QX2M""#));
    assert!(page
        .body
        .contains(r#"href="https://apps.apple.com/app/id1""#));
    assert!(page
        .body
        .contains(r#"href="https://play.google.com/store/apps/details?id=x&amp;hl=en""#));
    s.stop().await;
}

#[test]
fn deep_link_config_is_validated() {
    let mut c = westbound_server::Config::default();
    c.deeplinks.web_join_url = "https://example.com/".into();
    c.deeplinks.apple_app_ids = vec!["nodot".into()];
    c.deeplinks.android_package = "single".into();
    c.deeplinks.android_cert_sha256 = vec!["AB:CD".into()];
    c.deeplinks.app_store_url = "http://insecure".into();
    c.deeplinks.app_scheme = "1bad".into();
    let e = c.validate().unwrap_err().to_string();
    for key in [
        "web_join_url",
        "apple_app_ids",
        "android_package",
        "android_cert_sha256",
        "app_store_url",
        "app_scheme",
    ] {
        assert!(e.contains(key), "{key}: {e}");
    }
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
