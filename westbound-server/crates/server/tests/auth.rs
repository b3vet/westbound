//! N1.1 auth flow: device accounts, access tokens, refresh rotation and reuse detection,
//! expiry on the injected clock, device sign-in, logout, provider stubs, the gateway's
//! token check, error format and body limits.
mod common;

use common::{assert_error, DAY, T0};
use serde_json::json;
use sqlx::Row;
use westbound_server::auth::{self, routes::Session, TokenError};
use westbound_server::clock::Clock;
use westbound_server::names;
use westbound_server::profanity::ProfanityFilter;

#[tokio::test]
async fn device_create_returns_session_secret_and_profile() {
    let app = common::app().await;
    let d = app.create_device().await;
    let s = &d.session;
    assert!(auth::parse_account_id(&s.account_id).is_some());
    assert_eq!(s.token_type, "Bearer");
    assert_eq!(s.expires_in, 3_600);
    assert_eq!(s.expires_at, T0 + 3_600);
    assert_eq!(s.refresh_expires_at, T0 + 30 * DAY);
    assert_eq!(d.device_secret.len(), auth::SECRET_B64_LEN);
    assert_eq!(s.refresh_token.len(), auth::SECRET_B64_LEN);
    assert_ne!(d.device_secret, s.refresh_token);

    let p = &d.profile;
    assert_eq!(p.account_id, s.account_id);
    assert_eq!(p.full_name, names::full_name(&p.display_name, p.name_tag));
    assert!(names::validate(&p.display_name, ProfanityFilter::builtin()).is_ok());
    assert_eq!(p.name_changed_at, None);
    assert_eq!(p.next_rename_at, None);
    assert!(!p.linked.apple && !p.linked.google);

    // Only hashes are stored.
    let id: i64 = s.account_id.parse().unwrap();
    let row = sqlx::query("SELECT device_secret_hash FROM accounts WHERE id = ?")
        .bind(id)
        .fetch_one(app.db())
        .await
        .unwrap();
    let stored: Vec<u8> = row.get(0);
    let secret = auth::decode_secret(&d.device_secret).unwrap();
    assert_eq!(stored.len(), 32);
    assert_ne!(stored.as_slice(), secret.as_slice());
    assert_eq!(stored, app.state.auth.hash_device_secret(&secret));
    let hashes: Vec<Vec<u8>> =
        sqlx::query_scalar("SELECT token_hash FROM refresh_tokens WHERE account_id = ?")
            .bind(id)
            .fetch_all(app.db())
            .await
            .unwrap();
    let refresh = auth::decode_secret(&s.refresh_token).unwrap();
    assert_eq!(hashes, vec![auth::hash_refresh_token(&refresh).to_vec()]);

    // The access token works.
    let me = app.me(&s.access_token).await;
    assert_eq!(me.status, 200);
    assert_eq!(me.json["account_id"], json!(s.account_id));
    assert_eq!(me.json["display_name"], json!(p.display_name));

    // Two devices get two accounts.
    let d2 = app.create_device().await;
    assert_ne!(d2.session.account_id, s.account_id);
}

#[tokio::test]
async fn access_token_expires_on_the_injected_clock() {
    let app = common::app().await;
    let d = app.create_device().await;
    app.clock.advance(3_599);
    assert_eq!(app.me(&d.session.access_token).await.status, 200);
    app.clock.advance(1);
    let r = app.me(&d.session.access_token).await;
    assert_error(&r, 401, "token_expired");
    assert!(r.headers["www-authenticate"]
        .to_str()
        .unwrap()
        .starts_with("Bearer"));

    let r = app.refresh(&d.session.refresh_token).await;
    assert_eq!(r.status, 200, "{:?}", r.json);
    let s2: Session = serde_json::from_value(r.json).unwrap();
    assert_eq!(s2.account_id, d.session.account_id);
    assert_eq!(s2.expires_at, T0 + 3_600 + 3_600);
    assert_eq!(app.me(&s2.access_token).await.status, 200);
}

#[tokio::test]
async fn refresh_rotates_and_reuse_revokes_the_family() {
    let app = common::app().await;
    let d = app.create_device().await;
    let r1 = d.session.refresh_token.clone();

    let s2: Session = serde_json::from_value(app.refresh(&r1).await.json).unwrap();
    let s3: Session = serde_json::from_value(app.refresh(&s2.refresh_token).await.json).unwrap();
    assert_ne!(s2.refresh_token, r1);
    assert_ne!(s3.refresh_token, s2.refresh_token);

    // rotated_from chains the family, all in one family.
    let h = |t: &str| auth::hash_refresh_token(&auth::decode_secret(t).unwrap()).to_vec();
    let row = sqlx::query("SELECT rotated_from, family FROM refresh_tokens WHERE token_hash = ?")
        .bind(h(&s3.refresh_token))
        .fetch_one(app.db())
        .await
        .unwrap();
    assert_eq!(row.get::<Vec<u8>, _>(0), h(&s2.refresh_token));
    let families: i64 = sqlx::query_scalar("SELECT COUNT(DISTINCT family) FROM refresh_tokens")
        .fetch_one(app.db())
        .await
        .unwrap();
    assert_eq!(families, 1);

    // A second session (device sign-in) is its own family.
    let other = app.login(&d.session.account_id, &d.device_secret).await;
    assert_eq!(other.status, 200);
    let other_refresh = other.json["refresh_token"].as_str().unwrap().to_string();

    // Reusing r1 (already rotated) revokes the whole family, including s3's token.
    assert_error(&app.refresh(&r1).await, 401, "token_reused");
    assert_error(&app.refresh(&s3.refresh_token).await, 401, "token_revoked");
    assert_eq!(
        app.state
            .metrics
            .auth_refresh_reuse
            .load(std::sync::atomic::Ordering::Relaxed),
        1
    );
    // The other session is untouched.
    assert_eq!(app.refresh(&other_refresh).await.status, 200);
    // Garbage and unknown tokens.
    assert_error(&app.refresh("nope").await, 401, "invalid_token");
    assert_error(
        &app.refresh(&auth::b64(&[7u8; 32])).await,
        401,
        "invalid_token",
    );
}

#[tokio::test]
async fn refresh_token_expires_after_30_days() {
    let app = common::app().await;
    let d = app.create_device().await;
    let s2: Session =
        serde_json::from_value(app.refresh(&d.session.refresh_token).await.json).unwrap();
    // Each rotation gets a fresh 30 days.
    app.clock.advance(30 * DAY - 1);
    let r = app.refresh(&s2.refresh_token).await;
    assert_eq!(r.status, 200, "{:?}", r.json);
    let s3: Session = serde_json::from_value(r.json).unwrap();
    app.clock.advance(30 * DAY);
    assert_error(&app.refresh(&s3.refresh_token).await, 401, "token_expired");
    // Pruning removes expired rows.
    let pruned = westbound_server::accounts::prune_refresh_tokens(app.db(), app.clock.now())
        .await
        .unwrap();
    assert!(pruned >= 1);
    assert_error(&app.refresh(&s3.refresh_token).await, 401, "invalid_token");
}

#[tokio::test]
async fn device_login_recovers_the_account() {
    let app = common::app().await;
    let d = app.create_device().await;
    let id = &d.session.account_id;
    app.clock.advance(10 * DAY);

    let r = app.login(id, &d.device_secret).await;
    assert_eq!(r.status, 200, "{:?}", r.json);
    assert_eq!(r.json["account_id"], json!(id));
    assert_eq!(
        r.json["profile"]["display_name"],
        json!(d.profile.display_name)
    );
    let token = r.json["access_token"].as_str().unwrap();
    assert_eq!(app.me(token).await.json["account_id"], json!(id));
    let last_seen: i64 = sqlx::query_scalar("SELECT last_seen FROM accounts WHERE id = ?")
        .bind(id.parse::<i64>().unwrap())
        .fetch_one(app.db())
        .await
        .unwrap();
    assert_eq!(last_seen, T0 + 10 * DAY);

    let d2 = app.create_device().await;
    // Someone else's secret, an unknown account, a malformed secret: all 401.
    assert_error(
        &app.login(id, &d2.device_secret).await,
        401,
        "invalid_credentials",
    );
    assert_error(
        &app.login("999999", &d.device_secret).await,
        401,
        "invalid_credentials",
    );
    assert_error(&app.login(id, "short").await, 401, "invalid_credentials");
    // Malformed ids and bodies: 400.
    for bad in ["abc", "-1", "0", "1.5", "99999999999999999999"] {
        assert_error(&app.login(bad, &d.device_secret).await, 400, "invalid_body");
    }
    let r = app
        .call(
            "POST",
            "/api/v1/auth/device/login",
            None,
            Some(json!({ "account_id": id, "device_secret": d.device_secret, "extra": 1 })),
        )
        .await;
    assert_error(&r, 400, "invalid_body");
    let r = app
        .call(
            "POST",
            "/api/v1/auth/device/login",
            None,
            Some(json!({ "account_id": 5, "device_secret": d.device_secret })),
        )
        .await;
    assert_error(&r, 400, "invalid_body");
}

#[tokio::test]
async fn logout_revokes_one_session_or_all() {
    let app = common::app().await;
    let d = app.create_device().await;
    let other = app.login(&d.session.account_id, &d.device_secret).await;
    let other_refresh = other.json["refresh_token"].as_str().unwrap().to_string();
    let other_access = other.json["access_token"].as_str().unwrap().to_string();

    let r = app
        .call(
            "POST",
            "/api/v1/auth/logout",
            None,
            Some(json!({ "refresh_token": d.session.refresh_token })),
        )
        .await;
    assert_eq!(r.status, 204);
    assert_error(
        &app.refresh(&d.session.refresh_token).await,
        401,
        "token_revoked",
    );
    // The other device keeps working.
    let r = app.refresh(&other_refresh).await;
    assert_eq!(r.status, 200);
    let other_refresh = r.json["refresh_token"].as_str().unwrap().to_string();
    assert_eq!(app.me(&other_access).await.status, 200);

    // Unknown or malformed tokens: still 204.
    for t in [auth::b64(&[1u8; 32]), "x".to_string()] {
        let r = app
            .call(
                "POST",
                "/api/v1/auth/logout",
                None,
                Some(json!({ "refresh_token": t })),
            )
            .await;
        assert_eq!(r.status, 204);
    }

    // Everywhere: every refresh token and every access token dies.
    let third = app.login(&d.session.account_id, &d.device_secret).await;
    let third_refresh = third.json["refresh_token"].as_str().unwrap().to_string();
    let r = app
        .call(
            "POST",
            "/api/v1/auth/logout",
            None,
            Some(json!({ "refresh_token": other_refresh, "all_devices": true })),
        )
        .await;
    assert_eq!(r.status, 204);
    assert_error(&app.refresh(&third_refresh).await, 401, "token_revoked");
    assert_error(&app.me(&other_access).await, 401, "token_revoked");
    // The device secret still signs in, with the new token version.
    let again = app.login(&d.session.account_id, &d.device_secret).await;
    assert_eq!(again.status, 200);
    let token = again.json["access_token"].as_str().unwrap();
    assert_eq!(app.me(token).await.status, 200);
}

#[tokio::test]
async fn bearer_errors() {
    let app = common::app().await;
    assert_error(
        &app.call("GET", "/api/v1/me", None, None).await,
        401,
        "unauthorized",
    );
    assert_error(&app.me("garbage").await, 401, "invalid_token");
    let r = app
        .raw(
            "GET",
            "/api/v1/me",
            common::CLIENT,
            &[("authorization", "Basic dXNlcjpwYXNz")],
            Vec::new(),
        )
        .await;
    assert_error(&r, 401, "unauthorized");
    // A token signed with another secret.
    let other = common::app_with(|c| {
        c.auth.jwt_secret =
            westbound_server::config::Secret::new("another-secret-0123456789abcdef-xyz");
    })
    .await;
    let foreign = other.create_device().await;
    assert_error(
        &app.me(&foreign.session.access_token).await,
        401,
        "invalid_token",
    );
}

#[tokio::test]
async fn provider_routes_are_not_enabled() {
    // N11: still the MP-D2 shape while `[identity]` has no client ids (tests/identity.rs
    // covers them configured). Link needs a bearer token first.
    let app = common::app().await;
    let d = app.create_device().await;
    for (path, token) in [
        (
            "/api/v1/auth/link/apple",
            Some(d.session.access_token.as_str()),
        ),
        (
            "/api/v1/auth/link/google",
            Some(d.session.access_token.as_str()),
        ),
        ("/api/v1/auth/signin/apple", None),
        ("/api/v1/auth/signin/google", None),
    ] {
        let r = app
            .call("POST", path, token, Some(json!({ "id_token": "x" })))
            .await;
        assert_error(&r, 501, "provider_not_enabled");
    }
    let r = app
        .call(
            "POST",
            "/api/v1/auth/link/google",
            None,
            Some(json!({ "id_token": "x" })),
        )
        .await;
    assert_error(&r, 401, "unauthorized");
}

#[tokio::test]
async fn jwt_validation_for_the_gateway() {
    let app = common::app().await;
    let keys = &app.state.auth;
    let d = app.create_device().await;
    let id: i64 = d.session.account_id.parse().unwrap();
    let token = &d.session.access_token;

    let v = keys.verify(token, T0).unwrap();
    assert_eq!(v.account_id, id);
    assert_eq!(v.token_version, 0);
    assert_eq!(v.expires_at, T0 + 3_600);
    assert_eq!(keys.verify(token, T0 + 3_600), Err(TokenError::Expired));
    assert!(keys.verify_signature(token).is_ok());

    // Tampered payload or signature, alg=none, wrong audience: invalid.
    let parts: Vec<&str> = token.split('.').collect();
    // Flip a character in the middle of the signature (the last one only holds padding bits).
    let mut sig: Vec<char> = parts[2].chars().collect();
    sig[10] = if sig[10] == 'A' { 'B' } else { 'A' };
    let sig: String = sig.into_iter().collect();
    let tampered_sig = format!("{}.{}.{}", parts[0], parts[1], sig);
    assert_eq!(keys.verify(&tampered_sig, T0), Err(TokenError::Invalid));
    let claims = json!({"sub": "1", "iat": T0, "exp": T0 + 10, "jti": "x", "ver": 0,
        "iss": "westbound", "aud": "westbound-api"});
    let body = auth::b64(&serde_json::to_vec(&claims).unwrap());
    let none = format!("{}.{}.", auth::b64(br#"{"alg":"none","typ":"JWT"}"#), body);
    assert_eq!(keys.verify(&none, T0), Err(TokenError::Invalid));
    let swapped = format!("{}.{}.{}", parts[0], body, parts[2]);
    assert_eq!(keys.verify(&swapped, T0), Err(TokenError::Invalid));
    assert_eq!(keys.verify("", T0), Err(TokenError::Invalid));
    assert_eq!(keys.verify(&"a".repeat(5000), T0), Err(TokenError::Invalid));

    // The gateway's entry point, and through the protocol handshake.
    assert_eq!(
        auth::authenticate_hello(&app.state, token).await,
        Ok(protocol::AccountId(id as u64))
    );
    assert_eq!(
        auth::authenticate_hello(&app.state, "nope").await,
        Err(protocol::handshake::AuthError::Invalid)
    );
    let policy = protocol::handshake::HandshakePolicy::new(protocol::MapHash([7; 32]), 1);
    let hello = |t: &str| {
        protocol::ClientMsg::Hello(protocol::Hello {
            protocol_version: protocol::PROTOCOL_VERSION,
            client_build: 1,
            map_hash: protocol::MapHash([7; 32]),
            access_token: protocol::AccessToken(t.to_string()),
        })
    };
    let result = auth::authenticate_hello(&app.state, token).await;
    let mut hs = protocol::handshake::Handshake::new(policy.clone());
    assert!(matches!(
        hs.on_message(&hello(token), |_| result),
        protocol::handshake::Action::Reply(_)
    ));
    assert!(hs.is_established());

    westbound_server::accounts::set_ban(app.db(), id, Some(T0 + DAY))
        .await
        .unwrap();
    let result = auth::authenticate_hello(&app.state, token).await;
    assert_eq!(result, Err(protocol::handshake::AuthError::Banned));
    let mut hs = protocol::handshake::Handshake::new(policy);
    match hs.on_message(&hello(token), |_| result) {
        protocol::handshake::Action::Reject(protocol::ServerMsg::Error(e)) => {
            assert_eq!(e.code, protocol::ErrorCode::Banned)
        }
        other => panic!("{other:?}"),
    }
}

#[tokio::test]
async fn error_format_and_body_limits() {
    let app = common::app_with(|c| c.http.max_body_bytes = 512).await;
    let d = app.create_device().await;
    let big = json!({ "refresh_token": "x".repeat(1_000) });
    let r = app
        .call("POST", "/api/v1/auth/refresh", None, Some(big))
        .await;
    assert_error(&r, 413, "body_too_large");
    let r = app
        .raw(
            "POST",
            "/api/v1/auth/refresh",
            common::CLIENT,
            &[("content-type", "text/plain")],
            b"{}".to_vec(),
        )
        .await;
    assert_error(&r, 415, "unsupported_media_type");
    let r = app
        .raw(
            "POST",
            "/api/v1/auth/refresh",
            common::CLIENT,
            &[("content-type", "application/json")],
            b"{not json".to_vec(),
        )
        .await;
    assert_error(&r, 400, "invalid_body");
    let r = app
        .call("POST", "/api/v1/auth/refresh", None, Some(json!({})))
        .await;
    assert_error(&r, 400, "invalid_body");
    let r = app
        .call(
            "PATCH",
            "/api/v1/me",
            Some(&d.session.access_token),
            Some(json!({ "display_name": 5 })),
        )
        .await;
    assert_error(&r, 400, "invalid_body");
    assert_error(
        &app.call("GET", "/api/v1/auth/device", None, None).await,
        405,
        "method_not_allowed",
    );
    assert_error(
        &app.call("GET", "/api/v1/nope", None, None).await,
        404,
        "not_found",
    );
    assert_eq!(r.headers["cache-control"], "no-store");
}

#[tokio::test]
async fn ip_tags_are_stable_and_opaque() {
    let app = common::app().await;
    let keys = &app.state.auth;
    let a: std::net::IpAddr = "203.0.113.7".parse().unwrap();
    let b: std::net::IpAddr = "203.0.113.8".parse().unwrap();
    assert_eq!(keys.ip_tag(a), keys.ip_tag(a));
    assert_ne!(keys.ip_tag(a), keys.ip_tag(b));
    assert_eq!(keys.ip_tag(a).len(), 12);
    assert!(!keys.ip_tag(a).contains("203"));
}
