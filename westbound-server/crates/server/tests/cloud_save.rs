//! N11 cloud save: `GET/PUT /api/v1/save`: empty state, If-Match revisions and the 409
//! with the server copy, size cap, validation, the write rate limit, CORS for the web
//! build, disabled, and the deletion removing it.
mod common;

use common::{assert_error, TestApp, CLIENT, T0};
use serde_json::{json, Value};

async fn put(app: &TestApp, token: &str, if_match: Option<&str>, body: &Value) -> common::Resp {
    let auth = format!("Bearer {token}");
    let mut h: Vec<(&str, &str)> = vec![
        ("authorization", auth.as_str()),
        ("content-type", "application/json"),
    ];
    if let Some(m) = if_match {
        h.push(("if-match", m));
    }
    app.raw(
        "PUT",
        "/api/v1/save",
        CLIENT,
        &h,
        serde_json::to_vec(body).unwrap(),
    )
    .await
}

fn doc(xp: i64) -> Value {
    json!({ "data": { "version": 2, "bests": { "journey": 2010000 }, "stats": { "xp": xp } } })
}

#[tokio::test]
async fn revisions_conflicts_and_reads() {
    let app = common::app().await;
    let d = app.create_device().await;
    let t = d.session.access_token.as_str();
    let g = app.call("GET", "/api/v1/save", Some(t), None).await;
    assert_eq!(g.status, 200);
    assert_eq!(
        g.json,
        json!({"revision": 0, "updated_at": null, "bytes": 0, "data": null})
    );
    assert_eq!(g.headers["etag"], "\"0\"");
    assert_eq!(g.headers["cache-control"], "no-store");

    assert_error(
        &put(&app, t, None, &doc(1)).await,
        428,
        "precondition_required",
    );
    assert_error(
        &put(&app, t, Some("\"1\""), &doc(1)).await,
        409,
        "revision_conflict",
    );
    let p = put(&app, t, Some("\"0\""), &doc(10)).await;
    assert_eq!(p.status, 200, "{:?}", p.json);
    assert_eq!(p.json["revision"], json!(1));
    assert_eq!(p.json["updated_at"], json!(T0));
    assert_eq!(p.headers["etag"], "\"1\"");
    let bytes = p.json["bytes"].as_i64().unwrap();
    assert!(bytes > 20);

    // A second device that read revision 0 loses and gets the server copy to merge.
    app.clock.advance(5);
    let c = put(&app, t, Some("\"0\""), &doc(99)).await;
    assert_error(&c, 409, "revision_conflict");
    assert_eq!(c.json["save"]["revision"], json!(1));
    assert_eq!(c.json["save"]["data"]["stats"]["xp"], json!(10));
    assert_eq!(c.json["save"]["updated_at"], json!(T0));
    // It merges and writes on revision 1.
    let p2 = put(&app, t, Some("1"), &doc(99)).await;
    assert_eq!(p2.status, 200, "{:?}", p2.json);
    assert_eq!(p2.json["revision"], json!(2));
    let g = app.call("GET", "/api/v1/save", Some(t), None).await;
    assert_eq!(g.json["revision"], json!(2));
    assert_eq!(g.json["updated_at"], json!(T0 + 5));
    assert_eq!(g.json["data"]["stats"]["xp"], json!(99));
    assert_eq!(g.json["data"]["bests"]["journey"], json!(2010000));
    // One row per account: old revisions are not kept.
    let n: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM cloud_saves")
        .fetch_one(app.db())
        .await
        .unwrap();
    assert_eq!(n, 1);
    // Another account sees its own (none).
    let other = app.create_device().await;
    let g = app
        .call(
            "GET",
            "/api/v1/save",
            Some(&other.session.access_token),
            None,
        )
        .await;
    assert_eq!(g.json["revision"], json!(0));
    // Auth required.
    assert_error(
        &app.call("GET", "/api/v1/save", None, None).await,
        401,
        "unauthorized",
    );
}

#[tokio::test]
async fn validation_and_size_cap() {
    let app = common::app_with(|c| c.cloud_save.max_bytes = 2_048).await;
    let d = app.create_device().await;
    let t = d.session.access_token.as_str();
    assert_error(
        &put(&app, t, Some("0"), &json!({"data": [1, 2]})).await,
        400,
        "invalid_body",
    );
    assert_error(
        &put(&app, t, Some("0"), &json!({"data": {}, "x": 1})).await,
        400,
        "invalid_body",
    );
    let big = json!({"data": {"blob": "x".repeat(2_100)}});
    let r = put(&app, t, Some("0"), &big).await;
    assert_error(&r, 413, "save_too_large");
    assert_eq!(r.json["max_bytes"], json!(2_048));
    // Far over the body limit: refused before parsing.
    let huge = json!({"data": {"blob": "x".repeat(10_000)}});
    assert_eq!(put(&app, t, Some("0"), &huge).await.status, 413);
    // Just under fits.
    let ok = json!({"data": {"blob": "x".repeat(1_900)}});
    assert_eq!(put(&app, t, Some("0"), &ok).await.status, 200);
}

#[tokio::test]
async fn writes_are_rate_limited_per_account() {
    let app = common::app_with(|c| {
        c.cloud_save.writes_per_hour = 1;
        c.cloud_save.writes_burst = 2;
    })
    .await;
    let d = app.create_device().await;
    let t = d.session.access_token.as_str();
    assert_eq!(put(&app, t, Some("0"), &doc(1)).await.status, 200);
    assert_eq!(put(&app, t, Some("1"), &doc(2)).await.status, 200);
    assert_error(&put(&app, t, Some("2"), &doc(3)).await, 429, "rate_limited");
    // Reads are not under the write limit.
    assert_eq!(
        app.call("GET", "/api/v1/save", Some(t), None).await.status,
        200
    );
}

#[tokio::test]
async fn disabled_and_deleted() {
    let off = common::app_with(|c| c.cloud_save.enabled = false).await;
    let d = off.create_device().await;
    let t = d.session.access_token.as_str();
    assert_error(
        &off.call("GET", "/api/v1/save", Some(t), None).await,
        501,
        "cloud_save_not_enabled",
    );
    assert_error(
        &put(&off, t, Some("0"), &doc(1)).await,
        501,
        "cloud_save_not_enabled",
    );

    let app = common::app().await;
    let d = app.create_device().await;
    let t = d.session.access_token.as_str();
    assert_eq!(put(&app, t, Some("0"), &doc(1)).await.status, 200);
    assert_eq!(
        app.call("DELETE", "/api/v1/account", Some(t), None)
            .await
            .status,
        204
    );
    let n: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM cloud_saves")
        .fetch_one(app.db())
        .await
        .unwrap();
    assert_eq!(n, 0);
    let log: String =
        sqlx::query_scalar("SELECT detail FROM admin_log WHERE action = 'account_delete'")
            .fetch_one(app.db())
            .await
            .unwrap();
    assert!(log.contains("cloud_saves=1"), "{log}");
}

#[tokio::test]
async fn cors_allows_the_web_build_to_put_with_if_match() {
    let app = common::app().await;
    let r = app
        .raw(
            "OPTIONS",
            "/api/v1/save",
            CLIENT,
            &[
                ("origin", "https://b3vet.github.io"),
                ("access-control-request-method", "PUT"),
                (
                    "access-control-request-headers",
                    "authorization,content-type,if-match",
                ),
            ],
            Vec::new(),
        )
        .await;
    assert!(r.status < 300, "{}", r.status);
    let methods = r.headers["access-control-allow-methods"]
        .to_str()
        .unwrap()
        .to_string();
    assert!(methods.contains("PUT"), "{methods}");
    let allowed = r.headers["access-control-allow-headers"]
        .to_str()
        .unwrap()
        .to_ascii_lowercase();
    assert!(allowed.contains("if-match"), "{allowed}");
    let d = app.create_device().await;
    let g = app
        .raw(
            "GET",
            "/api/v1/save",
            CLIENT,
            &[
                ("origin", "https://b3vet.github.io"),
                (
                    "authorization",
                    &format!("Bearer {}", d.session.access_token),
                ),
            ],
            Vec::new(),
        )
        .await;
    let exposed = g.headers["access-control-expose-headers"]
        .to_str()
        .unwrap()
        .to_ascii_lowercase();
    assert!(exposed.contains("etag"), "{exposed}");
}
