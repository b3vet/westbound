//! N11: Sign in with Apple / Google against a fake identity provider on loopback (no
//! network): a JWKS issuer signing test tokens with test-only RSA keys
//! (`tests/data/idp_rsa_{a,b}.der`, public halves in `idp_jwks.json`), Apple's token and
//! revoke endpoints (client secrets checked against `apple_test_key.p8`'s public half).
//! Covers: providers off by default (the MP-D2 shapes), every ID-token check, nonces,
//! JWKS caching / rotation / outages, sign-in creating or finding the account, per-device
//! credentials, link with the conflict summaries, unlink and its last-method rule, Apple's
//! email forms, code exchange and revocation on unlink and deletion, and config checks.
mod common;

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};

use axum::extract::State;
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::Router;
use common::{assert_error, TestApp, T0};
use jsonwebtoken::{Algorithm, DecodingKey, EncodingKey, Header, Validation};
use serde_json::{json, Value};
use westbound_server::clock::Clock;
use westbound_server::config::{Config, Secret};

const GOOGLE_WEB: &str = "web-client.apps.googleusercontent.com";
const GOOGLE_IOS: &str = "ios-client.apps.googleusercontent.com";
const APPLE_WEB: &str = "com.b3vet.westbound.web";
const APPLE_IOS: &str = "com.b3vet.westbound";
const APPLE_TEAM: &str = "TEAM123456";
const APPLE_KEY_ID: &str = "KEY1234567";
const GOOGLE_ISS: &str = "https://accounts.google.com";
const APPLE_ISS: &str = "https://appleid.apple.com";
const REDIRECT: &str = "https://b3vet.github.io/westbound/";

/// What the fake provider serves and saw.
#[derive(Default)]
struct Idp {
    /// Keys in the JWKS (`a`, `b`).
    keys: Vec<&'static str>,
    max_age: Option<u64>,
    down: bool,
    jwks_hits: u32,
    /// Form bodies posted to /apple/token and /apple/revoke.
    token_forms: Vec<Vec<(String, String)>>,
    revoke_forms: Vec<Vec<(String, String)>>,
}

type Shared = Arc<Mutex<Idp>>;

fn jwks_doc() -> Value {
    serde_json::from_str(include_str!("data/idp_jwks.json")).unwrap()
}

async fn serve_jwks(State(s): State<Shared>) -> Response {
    let mut st = s.lock().unwrap();
    st.jwks_hits += 1;
    if st.down {
        return StatusCode::BAD_GATEWAY.into_response();
    }
    let doc = jwks_doc();
    let keys: Vec<Value> = st.keys.iter().map(|k| doc[*k].clone()).collect();
    let mut resp = axum::Json(json!({ "keys": keys })).into_response();
    if let Some(m) = st.max_age {
        resp.headers_mut().insert(
            header::CACHE_CONTROL,
            format!("public, max-age={m}").parse().unwrap(),
        );
    }
    resp
}

fn parse_form(body: &str) -> Vec<(String, String)> {
    body.split('&')
        .filter_map(|kv| kv.split_once('='))
        .map(|(k, v)| (dec(k), dec(v)))
        .collect()
}

fn dec(s: &str) -> String {
    let s = s.replace('+', " ");
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            out.push(u8::from_str_radix(&s[i + 1..i + 3], 16).unwrap());
            i += 3;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    String::from_utf8(out).unwrap()
}

async fn apple_token(State(s): State<Shared>, body: String) -> Response {
    let form = parse_form(&body);
    let code = form
        .iter()
        .find(|(k, _)| k == "code")
        .map(|(_, v)| v.clone())
        .unwrap_or_default();
    s.lock().unwrap().token_forms.push(form);
    if code == "bad-code" {
        return (
            StatusCode::BAD_REQUEST,
            axum::Json(json!({"error": "invalid_grant"})),
        )
            .into_response();
    }
    axum::Json(json!({
        "access_token": "apple-at", "token_type": "Bearer", "expires_in": 3600,
        "refresh_token": format!("apple-rt-{code}"), "id_token": "unused"
    }))
    .into_response()
}

async fn apple_revoke(State(s): State<Shared>, _h: HeaderMap, body: String) -> StatusCode {
    s.lock().unwrap().revoke_forms.push(parse_form(&body));
    StatusCode::OK
}

/// Starts the fake provider; returns its base URL.
async fn start_idp(s: Shared) -> String {
    let app = Router::new()
        .route("/google/certs", get(serve_jwks))
        .route("/apple/keys", get(serve_jwks))
        .route("/apple/token", post(apple_token))
        .route("/apple/revoke", post(apple_revoke))
        .with_state(s);
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr: SocketAddr = l.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(l, app).await.unwrap();
    });
    format!("http://{addr}")
}

fn idp(keys: &[&'static str]) -> Shared {
    Arc::new(Mutex::new(Idp {
        keys: keys.to_vec(),
        ..Idp::default()
    }))
}

fn configure(c: &mut Config, base: &str, apple_key: bool) {
    let i = &mut c.identity;
    i.google_client_ids = vec![GOOGLE_WEB.into(), GOOGLE_IOS.into()];
    i.google_jwks_url = format!("{base}/google/certs");
    i.apple_client_ids = vec![APPLE_WEB.into(), APPLE_IOS.into()];
    i.apple_web_redirect_uri = REDIRECT.into();
    i.apple_jwks_url = format!("{base}/apple/keys");
    i.apple_token_url = format!("{base}/apple/token");
    i.apple_revoke_url = format!("{base}/apple/revoke");
    if apple_key {
        i.apple_team_id = APPLE_TEAM.into();
        i.apple_key_id = APPLE_KEY_ID.into();
        i.apple_private_key = Secret::new(include_str!("data/apple_test_key.p8"));
    }
}

async fn app_with_idp(keys: &[&'static str], apple_key: bool) -> (TestApp, Shared) {
    let s = idp(keys);
    let base = start_idp(s.clone()).await;
    let app = common::app_with(|c| configure(c, &base, apple_key)).await;
    (app, s)
}

fn key(name: &str) -> EncodingKey {
    match name {
        "a" => EncodingKey::from_rsa_der(include_bytes!("data/idp_rsa_a.der")),
        _ => EncodingKey::from_rsa_der(include_bytes!("data/idp_rsa_b.der")),
    }
}

/// A token signed with key `k` (kid `test-<k>`).
fn sign(k: &str, claims: &Value) -> String {
    let mut h = Header::new(Algorithm::RS256);
    h.kid = Some(format!("test-{k}"));
    jsonwebtoken::encode(&h, claims, &key(k)).unwrap()
}

fn google_claims(sub: &str, nonce: &str) -> Value {
    json!({
        "iss": GOOGLE_ISS, "aud": GOOGLE_WEB, "sub": sub, "iat": T0, "exp": T0 + 3600,
        "nonce": nonce, "email": "player.one@gmail.com", "email_verified": true,
    })
}

fn apple_claims(sub: &str, nonce: &str) -> Value {
    json!({
        "iss": APPLE_ISS, "aud": APPLE_WEB, "sub": sub, "iat": T0, "exp": T0 + 600,
        "nonce": nonce, "email": "abc123@privaterelay.appleid.com",
        "email_verified": "true", "is_private_email": "true",
    })
}

async fn nonce(app: &TestApp) -> String {
    let r = app.call("POST", "/api/v1/auth/nonce", None, None).await;
    assert_eq!(r.status, 200, "{:?}", r.json);
    assert_eq!(
        r.json["expires_at"].as_i64().unwrap(),
        app.clock.now() + 600
    );
    r.json["nonce"].as_str().unwrap().to_string()
}

async fn signin(app: &TestApp, provider: &str, body: Value) -> common::Resp {
    app.call(
        "POST",
        &format!("/api/v1/auth/signin/{provider}"),
        None,
        Some(body),
    )
    .await
}

async fn link(app: &TestApp, token: &str, provider: &str, body: Value) -> common::Resp {
    app.call(
        "POST",
        &format!("/api/v1/auth/link/{provider}"),
        Some(token),
        Some(body),
    )
    .await
}

async fn unlink(app: &TestApp, token: &str, provider: &str) -> common::Resp {
    app.call(
        "POST",
        &format!("/api/v1/auth/unlink/{provider}"),
        Some(token),
        None,
    )
    .await
}

async fn google_signin(app: &TestApp, sub: &str) -> common::Resp {
    let n = nonce(app).await;
    let t = sign("a", &google_claims(sub, &n));
    signin(app, "google", json!({ "id_token": t, "nonce": n })).await
}

#[tokio::test]
async fn providers_are_off_until_configured() {
    let app = common::app().await;
    let r = app.call("GET", "/api/v1/auth/providers", None, None).await;
    assert_eq!(r.status, 200);
    assert_eq!(r.json["apple"]["enabled"], json!(false));
    assert_eq!(r.json["google"]["enabled"], json!(false));
    assert_eq!(r.json["google"]["client_id"], json!(""));
    assert_eq!(r.json["nonce_required"], json!(true));
    assert_eq!(
        r.json["cloud_save"],
        json!({"enabled": true, "max_bytes": 65536})
    );
    let body = json!({ "id_token": "x.y.z", "nonce": "n" });
    for p in ["apple", "google"] {
        assert_error(
            &signin(&app, p, body.clone()).await,
            501,
            "provider_not_enabled",
        );
    }
    let d = app.create_device().await;
    let tok = &d.session.access_token;
    assert_error(
        &link(&app, tok, "google", body.clone()).await,
        501,
        "provider_not_enabled",
    );
    assert_error(
        &signin(&app, "facebook", body.clone()).await,
        404,
        "not_found",
    );
    // Nonces work regardless (the client asks for one before knowing).
    assert!(!nonce(&app).await.is_empty());
}

#[tokio::test]
async fn providers_endpoint_lists_the_web_clients() {
    let (app, _s) = app_with_idp(&["a"], false).await;
    let r = app.call("GET", "/api/v1/auth/providers", None, None).await;
    assert_eq!(
        r.json["google"],
        json!({"enabled": true, "client_id": GOOGLE_WEB})
    );
    assert_eq!(
        r.json["apple"],
        json!({"enabled": true, "client_id": APPLE_WEB, "redirect_uri": REDIRECT})
    );
}

#[tokio::test]
async fn google_sign_in_creates_then_finds_the_account_with_device_credentials() {
    let (app, _s) = app_with_idp(&["a"], false).await;
    let r = google_signin(&app, "g-111").await;
    assert_eq!(r.status, 201, "{:?}", r.json);
    assert_eq!(r.json["created"], json!(true));
    let id = r.json["account_id"].as_str().unwrap().to_string();
    let secret1 = r.json["device_secret"].as_str().unwrap().to_string();
    assert_eq!(
        r.json["profile"]["linked"],
        json!({"apple": false, "google": true})
    );
    let ids = &r.json["profile"]["identities"];
    assert_eq!(ids[0]["provider"], json!("google"));
    assert_eq!(ids[0]["email_hint"], json!("p***@gmail.com"));
    assert_eq!(ids[0]["private_email"], json!(false));
    // Nothing of the address beyond the hint is stored.
    let stored: Vec<String> =
        sqlx::query_scalar("SELECT COALESCE(email_hint, '') FROM identity_links")
            .fetch_all(app.db())
            .await
            .unwrap();
    assert_eq!(stored, vec!["p***@gmail.com".to_string()]);

    // A second device: same account, its own credential.
    let r2 = google_signin(&app, "g-111").await;
    assert_eq!(r2.status, 200, "{:?}", r2.json);
    assert_eq!(r2.json["created"], json!(false));
    assert_eq!(r2.json["account_id"], json!(id));
    let secret2 = r2.json["device_secret"].as_str().unwrap().to_string();
    assert_ne!(secret1, secret2);
    // Both devices renew the usual way.
    assert_eq!(app.login(&id, &secret1).await.status, 200);
    let l2 = app.login(&id, &secret2).await;
    assert_eq!(l2.status, 200, "{:?}", l2.json);
    assert_eq!(l2.json["profile"]["linked"]["google"], json!(true));
    assert_error(
        &app.login(&id, &"A".repeat(43)).await,
        401,
        "invalid_credentials",
    );
    // The access token works.
    let me = app.me(r2.json["access_token"].as_str().unwrap()).await;
    assert_eq!(me.status, 200);
    assert_eq!(me.json["identities"][0]["provider"], json!("google"));
}

#[tokio::test]
async fn device_credentials_are_capped_per_account() {
    let (app, _s) = app_with_idp(&["a"], false).await;
    let first = google_signin(&app, "g-cap").await;
    let id = first.json["account_id"].as_str().unwrap().to_string();
    let mut secrets = Vec::new();
    for _ in 0..12 {
        app.clock.advance(1);
        let r = google_signin(&app, "g-cap").await;
        secrets.push(r.json["device_secret"].as_str().unwrap().to_string());
    }
    let n: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM device_secrets")
        .fetch_one(app.db())
        .await
        .unwrap();
    assert_eq!(n, 10);
    // The oldest extra ones went; the newest and the account's first still work.
    assert_error(
        &app.login(&id, &secrets[0]).await,
        401,
        "invalid_credentials",
    );
    assert_eq!(app.login(&id, &secrets[11]).await.status, 200);
    let first_secret = first.json["device_secret"].as_str().unwrap();
    assert_eq!(app.login(&id, first_secret).await.status, 200);
}

#[tokio::test]
async fn id_token_checks() {
    let (app, _s) = app_with_idp(&["a"], false).await;
    let n = nonce(&app).await;
    let ok = google_claims("g-1", &n);
    let try_claims = |claims: Value, k: &'static str| {
        let t = sign(k, &claims);
        let n = n.clone();
        let app = &app;
        async move { signin(app, "google", json!({ "id_token": t, "nonce": n })).await }
    };
    let with = |k: &str, v: Value| {
        let mut c = ok.clone();
        c[k] = v;
        c
    };
    assert_error(
        &try_claims(with("aud", json!("someone-else")), "a").await,
        401,
        "invalid_id_token",
    );
    assert_error(
        &try_claims(with("iss", json!("https://evil.example")), "a").await,
        401,
        "invalid_id_token",
    );
    assert_error(
        &try_claims(with("exp", json!(T0 - 61)), "a").await,
        401,
        "id_token_expired",
    );
    assert_error(
        &try_claims(with("iat", json!(T0 + 3600)), "a").await,
        401,
        "invalid_id_token",
    );
    assert_error(
        &try_claims(with("sub", json!("")), "a").await,
        401,
        "invalid_id_token",
    );
    assert_error(
        &try_claims(with("nonce", json!("other")), "a").await,
        400,
        "invalid_nonce",
    );
    // Signed with key b but naming kid a: bad signature.
    let mut h = Header::new(Algorithm::RS256);
    h.kid = Some("test-a".into());
    let forged = jsonwebtoken::encode(&h, &ok, &key("b")).unwrap();
    assert_error(
        &signin(&app, "google", json!({ "id_token": forged, "nonce": n })).await,
        401,
        "invalid_id_token",
    );
    // HS256 with a guessable secret, alg none, garbage.
    let hs = jsonwebtoken::encode(
        &Header::new(Algorithm::HS256),
        &ok,
        &EncodingKey::from_secret(b"x"),
    )
    .unwrap();
    for t in [hs.as_str(), "not-a-jwt", "e30.e30."] {
        assert_error(
            &signin(&app, "google", json!({ "id_token": t, "nonce": n })).await,
            401,
            "invalid_id_token",
        );
    }
    // Nonce: missing, made up, expired.
    let t = sign("a", &ok);
    assert_error(
        &signin(&app, "google", json!({ "id_token": t })).await,
        400,
        "invalid_nonce",
    );
    assert_error(
        &signin(&app, "google", json!({ "id_token": t, "nonce": "made-up" })).await,
        400,
        "invalid_nonce",
    );
    // An aud list with one of ours, the token within the skew, and the iOS client.
    let r = try_claims(with("aud", json!(["x", GOOGLE_IOS])), "a").await;
    assert_eq!(r.status, 201, "{:?}", r.json);
    // 30 s past `exp`: inside the 60 s skew (with a fresh nonce: the first one is 3630 s
    // old by then, past its 600 s).
    app.clock.advance(3_600 + 30);
    let n2 = nonce(&app).await;
    let late = sign("a", &google_claims("g-1", &n2));
    let r = signin(&app, "google", json!({ "id_token": late, "nonce": n2 })).await;
    assert_eq!(r.status, 200, "within the 60 s skew: {:?}", r.json);
    assert_error(
        &signin(
            &app,
            "google",
            json!({ "id_token": sign("a", &with("exp", json!(T0 + 99_999))), "nonce": n }),
        )
        .await,
        400,
        "invalid_nonce",
    );
    // Unknown fields are refused.
    assert_error(
        &signin(&app, "google", json!({ "id_token": t, "nonce": n, "x": 1 })).await,
        400,
        "invalid_body",
    );
}

#[tokio::test]
async fn hashed_nonce_and_optional_nonce() {
    use sha2::{Digest, Sha256};
    let (app, _s) = app_with_idp(&["a"], false).await;
    let n = nonce(&app).await;
    let hashed: String = Sha256::digest(n.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    let t = sign("a", &google_claims("g-h", &hashed));
    let r = signin(&app, "google", json!({ "id_token": t, "nonce": n })).await;
    assert_eq!(r.status, 201, "{:?}", r.json);

    let s = idp(&["a"]);
    let base = start_idp(s).await;
    let app2 = common::app_with(|c| {
        configure(c, &base, false);
        c.identity.require_nonce = false;
    })
    .await;
    let mut c = google_claims("g-o", "");
    c.as_object_mut().unwrap().remove("nonce");
    let r = signin(&app2, "google", json!({ "id_token": sign("a", &c) })).await;
    assert_eq!(r.status, 201, "{:?}", r.json);
}

#[tokio::test]
async fn jwks_cache_rotation_and_outages() {
    let s = idp(&["a"]);
    s.lock().unwrap().max_age = Some(1_000);
    let base = start_idp(s.clone()).await;
    let app = common::app_with(|c| configure(c, &base, false)).await;
    let hits = || s.lock().unwrap().jwks_hits;
    assert_eq!(google_signin(&app, "g-1").await.status, 201);
    assert_eq!(google_signin(&app, "g-1").await.status, 200);
    assert_eq!(hits(), 1, "cached");
    // Rotation: the provider now signs with b; an unknown kid refetches once (at most
    // once per jwks_refetch_min_secs, 60 s).
    s.lock().unwrap().keys = vec!["a", "b"];
    app.clock.advance(61);
    let n = nonce(&app).await;
    let tb = sign("b", &google_claims("g-1", &n));
    let r = signin(&app, "google", json!({ "id_token": tb, "nonce": n })).await;
    assert_eq!(r.status, 200, "{:?}", r.json);
    assert_eq!(hits(), 2);
    // A made-up kid does not refetch again within jwks_refetch_min_secs.
    let mut h = Header::new(Algorithm::RS256);
    h.kid = Some("nope".into());
    let bogus = jsonwebtoken::encode(&h, &google_claims("g-1", &n), &key("a")).unwrap();
    for _ in 0..3 {
        assert_error(
            &signin(&app, "google", json!({ "id_token": bogus, "nonce": n })).await,
            401,
            "invalid_id_token",
        );
    }
    assert_eq!(hits(), 2);
    // Expired cache + provider down: the old keys keep working.
    app.clock.advance(1_001);
    s.lock().unwrap().down = true;
    let n = nonce(&app).await;
    let ta = sign(
        "a",
        &json!({
            "iss": GOOGLE_ISS, "aud": GOOGLE_WEB, "sub": "g-1", "iat": T0 + 1001,
            "exp": T0 + 5000, "nonce": n,
        }),
    );
    let r = signin(&app, "google", json!({ "id_token": ta, "nonce": n })).await;
    assert_eq!(r.status, 200, "stale-if-error: {:?}", r.json);
    assert_eq!(hits(), 3);
    // Down with no cache at all: 503, not "invalid".
    let s2 = idp(&["a"]);
    s2.lock().unwrap().down = true;
    let base2 = start_idp(s2).await;
    let app2 = common::app_with(|c| configure(c, &base2, false)).await;
    assert_error(
        &google_signin(&app2, "g-2").await,
        503,
        "provider_unavailable",
    );
}

#[tokio::test]
async fn link_keeps_progress_and_conflicts_show_both_accounts() {
    let (app, _s) = app_with_idp(&["a"], false).await;
    // Device account Y links Google G.
    let y = app.create_device().await;
    let ty = y.session.access_token.clone();
    let n = nonce(&app).await;
    let tok = sign("a", &google_claims("g-shared", &n));
    let body = json!({ "id_token": tok, "nonce": n });
    let r = link(&app, &ty, "google", body.clone()).await;
    assert_eq!(r.status, 200, "{:?}", r.json);
    assert_eq!(r.json["account_id"], json!(y.session.account_id));
    assert_eq!(r.json["linked"]["google"], json!(true));
    // Again: idempotent.
    assert_eq!(link(&app, &ty, "google", body.clone()).await.status, 200);
    // Y uploads a cloud save.
    let put = app
        .raw(
            "PUT",
            "/api/v1/save",
            common::CLIENT,
            &[
                ("authorization", &format!("Bearer {ty}")),
                ("content-type", "application/json"),
                ("if-match", "\"0\""),
            ],
            serde_json::to_vec(&json!({"data": {"version": 2, "stats": {"xp": 36123, "runs": 9}}}))
                .unwrap(),
        )
        .await;
    assert_eq!(put.status, 200, "{:?}", put.json);

    // Device account Z tries to link the same identity.
    let z = app.create_device().await;
    let r = link(&app, &z.session.access_token, "google", body.clone()).await;
    assert_error(&r, 409, "identity_in_use");
    let c = &r.json["conflict"];
    assert_eq!(c["provider"], json!("google"));
    assert_eq!(c["current"]["account_id"], json!(z.session.account_id));
    assert_eq!(c["current"]["cloud_save"], Value::Null);
    assert_eq!(c["other"]["account_id"], json!(y.session.account_id));
    assert_eq!(c["other"]["full_name"], json!(y.profile.full_name));
    assert_eq!(c["other"]["linked"]["google"], json!(true));
    assert_eq!(c["other"]["cloud_save"]["xp"], json!(36123));
    assert_eq!(c["other"]["cloud_save"]["runs"], json!(9));
    assert_eq!(c["other"]["cloud_save"]["revision"], json!(1));
    assert_eq!(c["other"]["runs"], json!(0));
    // Z chooses to switch: sign-in with the same token lands on Y.
    let s = signin(&app, "google", body.clone()).await;
    assert_eq!(s.status, 200, "{:?}", s.json);
    assert_eq!(s.json["account_id"], json!(y.session.account_id));
    // Z keeps nothing linked; a second Google identity on Y is refused.
    let n2 = nonce(&app).await;
    let other = sign("a", &google_claims("g-other", &n2));
    assert_error(
        &link(
            &app,
            &ty,
            "google",
            json!({ "id_token": other, "nonce": n2 }),
        )
        .await,
        409,
        "provider_already_linked",
    );
}

#[tokio::test]
async fn unlink_rules() {
    let (app, _s) = app_with_idp(&["a"], false).await;
    let y = app.create_device().await;
    let ty = y.session.access_token.clone();
    let n = nonce(&app).await;
    let tok = sign("a", &google_claims("g-u", &n));
    assert_eq!(
        link(&app, &ty, "google", json!({ "id_token": tok, "nonce": n }))
            .await
            .status,
        200
    );
    assert_error(&unlink(&app, &ty, "apple").await, 404, "not_linked");
    // An account with no device credential and one provider cannot drop it.
    let id: i64 = y.session.account_id.parse().unwrap();
    sqlx::query("UPDATE accounts SET device_secret_hash = NULL WHERE id = ?")
        .bind(id)
        .execute(app.db())
        .await
        .unwrap();
    assert_error(
        &unlink(&app, &ty, "google").await,
        409,
        "last_sign_in_method",
    );
    // With a device credential (a sign-in on a device), it can.
    assert_eq!(google_signin(&app, "g-u").await.status, 200);
    let r = unlink(&app, &ty, "google").await;
    assert_eq!(r.status, 200, "{:?}", r.json);
    assert_eq!(r.json["linked"]["google"], json!(false));
    assert_eq!(r.json["identities"], json!([]));
    assert_error(&unlink(&app, &ty, "google").await, 404, "not_linked");
    // The identity is free again: a sign-in now makes a new account.
    assert_eq!(google_signin(&app, "g-u").await.status, 201);
}

fn form_get<'a>(f: &'a [(String, String)], k: &str) -> Option<&'a str> {
    f.iter().find(|(a, _)| a == k).map(|(_, v)| v.as_str())
}

fn check_client_secret(secret: &str, client_id: &str) {
    let pubkey: Value = serde_json::from_str(include_str!("data/apple_test_key.pub.json")).unwrap();
    let key = DecodingKey::from_ec_components(
        pubkey["x"].as_str().unwrap(),
        pubkey["y"].as_str().unwrap(),
    )
    .unwrap();
    let mut v = Validation::new(Algorithm::ES256);
    v.validate_exp = false;
    v.set_audience(&[APPLE_ISS]);
    v.set_issuer(&[APPLE_TEAM]);
    v.sub = Some(client_id.into());
    let header = jsonwebtoken::decode_header(secret).unwrap();
    assert_eq!(header.kid.as_deref(), Some(APPLE_KEY_ID));
    let data = jsonwebtoken::decode::<Value>(secret, &key, &v).unwrap();
    assert_eq!(
        data.claims["exp"].as_i64().unwrap() - data.claims["iat"].as_i64().unwrap(),
        300
    );
}

#[tokio::test]
async fn apple_code_exchange_private_email_and_revocation() {
    let (app, s) = app_with_idp(&["a"], true).await;
    let n = nonce(&app).await;
    let t = sign("a", &apple_claims("a-001", &n));
    let r = signin(
        &app,
        "apple",
        json!({ "id_token": t, "nonce": n, "authorization_code": "code-1" }),
    )
    .await;
    assert_eq!(r.status, 201, "{:?}", r.json);
    let ids = &r.json["profile"]["identities"][0];
    assert_eq!(ids["provider"], json!("apple"));
    assert_eq!(ids["email_hint"], Value::Null);
    assert_eq!(ids["private_email"], json!(true));
    {
        let st = s.lock().unwrap();
        assert_eq!(st.token_forms.len(), 1);
        let f = &st.token_forms[0];
        assert_eq!(form_get(f, "client_id"), Some(APPLE_WEB));
        assert_eq!(form_get(f, "code"), Some("code-1"));
        assert_eq!(form_get(f, "grant_type"), Some("authorization_code"));
        assert_eq!(form_get(f, "redirect_uri"), Some(REDIRECT));
        check_client_secret(form_get(f, "client_secret").unwrap(), APPLE_WEB);
    }
    // Stored sealed, never in the clear.
    let sealed: Vec<u8> = sqlx::query_scalar(
        "SELECT apple_refresh_sealed FROM identity_links WHERE provider = 'apple'",
    )
    .fetch_one(app.db())
    .await
    .unwrap();
    assert!(!String::from_utf8_lossy(&sealed).contains("apple-rt-code-1"));

    // Deletion revokes it.
    let tok = r.json["access_token"].as_str().unwrap();
    let d = app.call("DELETE", "/api/v1/account", Some(tok), None).await;
    assert_eq!(d.status, 204, "{:?}", d.json);
    {
        let st = s.lock().unwrap();
        assert_eq!(st.revoke_forms.len(), 1);
        let f = &st.revoke_forms[0];
        assert_eq!(form_get(f, "token"), Some("apple-rt-code-1"));
        assert_eq!(form_get(f, "token_type_hint"), Some("refresh_token"));
        assert_eq!(form_get(f, "client_id"), Some(APPLE_WEB));
        check_client_secret(form_get(f, "client_secret").unwrap(), APPLE_WEB);
    }
    for table in [
        "identity_links",
        "device_secrets",
        "cloud_saves",
        "accounts",
    ] {
        let n: i64 =
            sqlx::query_scalar(sqlx::AssertSqlSafe(format!("SELECT COUNT(*) FROM {table}")))
                .fetch_one(app.db())
                .await
                .unwrap();
        assert_eq!(n, 0, "{table}");
    }
}

#[tokio::test]
async fn apple_unlink_revokes_ios_client_and_bad_codes_are_tolerated() {
    let (app, s) = app_with_idp(&["a"], true).await;
    let y = app.create_device().await;
    let ty = y.session.access_token.clone();
    let n = nonce(&app).await;
    let mut c = apple_claims("a-002", &n);
    c["aud"] = json!(APPLE_IOS);
    c["email"] = json!("Real.Person@icloud.com");
    c["is_private_email"] = json!(false);
    let t = sign("a", &c);
    let r = link(
        &app,
        &ty,
        "apple",
        json!({ "id_token": t, "nonce": n, "authorization_code": "code-ios" }),
    )
    .await;
    assert_eq!(r.status, 200, "{:?}", r.json);
    assert_eq!(
        r.json["identities"][0]["email_hint"],
        json!("R***@icloud.com")
    );
    {
        let st = s.lock().unwrap();
        // The iOS client's exchange names no redirect URL.
        assert_eq!(form_get(&st.token_forms[0], "redirect_uri"), None);
        assert_eq!(form_get(&st.token_forms[0], "client_id"), Some(APPLE_IOS));
    }
    let r = unlink(&app, &ty, "apple").await;
    assert_eq!(r.status, 200, "{:?}", r.json);
    {
        let st = s.lock().unwrap();
        assert_eq!(
            form_get(&st.revoke_forms[0], "token"),
            Some("apple-rt-code-ios")
        );
        assert_eq!(form_get(&st.revoke_forms[0], "client_id"), Some(APPLE_IOS));
    }
    // Apple refusing the code does not block the sign-in (nothing to revoke later).
    let n = nonce(&app).await;
    let t = sign("a", &apple_claims("a-003", &n));
    let r = signin(
        &app,
        "apple",
        json!({ "id_token": t, "nonce": n, "authorization_code": "bad-code" }),
    )
    .await;
    assert_eq!(r.status, 201, "{:?}", r.json);
    let tok = r.json["access_token"].as_str().unwrap();
    assert_eq!(
        app.call("DELETE", "/api/v1/account", Some(tok), None)
            .await
            .status,
        204
    );
    assert_eq!(
        s.lock().unwrap().revoke_forms.len(),
        1,
        "nothing stored to revoke"
    );
}

#[tokio::test]
async fn without_the_apple_key_revocation_is_a_no_op() {
    let (app, s) = app_with_idp(&["a"], false).await;
    let n = nonce(&app).await;
    let t = sign("a", &apple_claims("a-004", &n));
    let r = signin(
        &app,
        "apple",
        json!({ "id_token": t, "nonce": n, "authorization_code": "code-x" }),
    )
    .await;
    assert_eq!(r.status, 201, "{:?}", r.json);
    let tok = r.json["access_token"].as_str().unwrap();
    assert_eq!(
        app.call("DELETE", "/api/v1/account", Some(tok), None)
            .await
            .status,
        204
    );
    let st = s.lock().unwrap();
    assert!(st.token_forms.is_empty() && st.revoke_forms.is_empty());
}

#[tokio::test]
async fn banned_identity_cannot_sign_in() {
    let (app, _s) = app_with_idp(&["a"], false).await;
    let r = google_signin(&app, "g-ban").await;
    let id: i64 = r.json["account_id"].as_str().unwrap().parse().unwrap();
    westbound_server::accounts::set_ban(app.db(), id, Some(T0 + 1_000))
        .await
        .unwrap();
    let r = google_signin(&app, "g-ban").await;
    assert_error(&r, 403, "banned");
    assert_eq!(r.json["banned_until"], json!(T0 + 1_000));
}

#[tokio::test]
async fn identity_config_validation_and_env() {
    let env = |pairs: &[(&str, &str)]| -> Vec<(String, String)> {
        let mut v: Vec<(String, String)> = vec![
            ("WB_AUTH__JWT_SECRET".into(), common::JWT_SECRET.into()),
            (
                "WB_AUTH__DEVICE_SECRET_PEPPER".into(),
                common::PEPPER.into(),
            ),
        ];
        v.extend(pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())));
        v
    };
    let c = Config::load(
        None,
        env(&[
            (
                "WB_IDENTITY__GOOGLE_CLIENT_IDS",
                "a.apps.googleusercontent.com, b.apps.googleusercontent.com",
            ),
            ("WB_IDENTITY__APPLE_CLIENT_IDS", "com.x.web"),
            (
                "WB_IDENTITY__APPLE_WEB_REDIRECT_URI",
                "https://b3vet.github.io/westbound/",
            ),
            ("WB_IDENTITY__APPLE_TEAM_ID", APPLE_TEAM),
            ("WB_IDENTITY__APPLE_KEY_ID", APPLE_KEY_ID),
            (
                "WB_IDENTITY__APPLE_PRIVATE_KEY",
                &include_str!("data/apple_test_key.p8").replace('\n', "\\n"),
            ),
            ("WB_CLOUD_SAVE__MAX_BYTES", "32768"),
        ]),
    )
    .unwrap();
    assert_eq!(c.identity.google_client_ids.len(), 2);
    assert!(c.identity.apple_key_configured());
    assert_eq!(c.cloud_save.max_bytes, 32_768);
    assert!(c.to_redacted_toml().contains("<redacted>"));
    assert!(!c.to_redacted_toml().contains("PRIVATE KEY"));

    let bad = |f: &dyn Fn(&mut Config)| {
        let mut c = Config::default();
        c.auth.jwt_secret = Secret::new(common::JWT_SECRET);
        c.auth.device_secret_pepper = Secret::new(common::PEPPER);
        f(&mut c);
        c.validate().unwrap_err().0.join("\n")
    };
    assert!(
        bad(&|c| c.identity.google_jwks_url = "http://example.com/certs".into())
            .contains("google_jwks_url")
    );
    assert!(bad(&|c| {
        c.identity.apple_client_ids = vec!["x".into()];
        c.identity.apple_team_id = "TEAM123456".into();
        c.identity.apple_key_id = "short".into();
        c.identity.apple_private_key =
            Secret::new("-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----");
    })
    .contains("apple_key_id"));
    assert!(bad(&|c| {
        c.identity.apple_client_ids = vec!["x".into()];
        c.identity.apple_team_id = "TEAM123456".into();
        c.identity.apple_key_id = "KEY1234567".into();
        c.identity.apple_private_key =
            Secret::new("-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----");
    })
    .contains("apple_private_key"));
    assert!(bad(&|c| c.identity.google_web_client_id = "z".into()).contains("google_web_client_id"));
    assert!(bad(&|c| c.cloud_save.max_bytes = 10).contains("cloud_save.max_bytes"));
    assert!(
        bad(&|c| c.identity.google_client_ids = vec![" x".into()]).contains("google_client_ids")
    );
}
