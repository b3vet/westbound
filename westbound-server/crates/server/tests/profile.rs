//! N1.1 profile: `GET/PATCH /me` rename rules (30-day cooldown, tag uniqueness),
//! `DELETE /account` cascade, and bans on sign-in, refresh and `/me`.
mod common;

use common::{assert_error, DAY, T0};
use serde_json::json;
use westbound_server::accounts;

#[tokio::test]
async fn rename_rules_and_cooldown() {
    let app = common::app().await;
    let d = app.create_device().await;
    let t = d.session.access_token.clone();

    for bad in [
        "ab",
        "abcdefghijklmnopq",
        "",
        "   ",
        "a#bc",
        "émile",
        "tab\tname",
        "-abc",
        "abc.",
        "a__b",
        "a. b",
        "1234",
        "..",
    ] {
        assert_error(&app.rename(&t, bad).await, 400, "invalid_name");
    }
    for rude in ["Fuck3r", "sh1tlord", "Big Ass", "0rospu", "S1kt1r"] {
        assert_error(&app.rename(&t, rude).await, 400, "name_not_allowed");
    }
    assert_error(
        &app.rename(&t, &d.profile.display_name).await,
        400,
        "name_unchanged",
    );
    // Nothing above counted as a rename.
    assert_eq!(app.me(&t).await.json["name_changed_at"], json!(null));

    let r = app.rename(&t, "  Şahin 34  ").await;
    assert_eq!(r.status, 200, "{:?}", r.json);
    assert_eq!(r.json["display_name"], json!("Şahin 34"));
    // The tag was free for the new name, so it is kept.
    assert_eq!(r.json["name_tag"], json!(d.profile.name_tag));
    assert_eq!(r.json["name_changed_at"], json!(T0));
    assert_eq!(r.json["next_rename_at"], json!(T0 + 30 * DAY));

    let r = app.rename(&t, "Kartal").await;
    assert_error(&r, 409, "rename_cooldown");
    assert_eq!(r.json["next_rename_at"], json!(T0 + 30 * DAY));
    app.clock.advance(30 * DAY - 1);
    // The access token expired meanwhile; sign in again.
    let t = app
        .login(&d.session.account_id, &d.device_secret)
        .await
        .json["access_token"]
        .as_str()
        .unwrap()
        .to_string();
    assert_error(&app.rename(&t, "Kartal").await, 409, "rename_cooldown");
    app.clock.advance(1);
    let r = app.rename(&t, "Kartal").await;
    assert_eq!(r.status, 200, "{:?}", r.json);
    assert_eq!(
        r.json["full_name"],
        json!(format!(
            "Kartal#{:04}",
            r.json["name_tag"].as_u64().unwrap()
        ))
    );
}

#[tokio::test]
async fn name_tag_stays_unique() {
    let app = common::app().await;
    let a = app.create_device().await;
    let b = app.create_device().await;
    let (a_id, b_id): (i64, i64) = (
        a.session.account_id.parse().unwrap(),
        b.session.account_id.parse().unwrap(),
    );
    // Give B the same tag as A, then both take the same name (case-insensitively).
    sqlx::query("UPDATE accounts SET display_name = 'Bravo', tag = ? WHERE id = ?")
        .bind(a.profile.name_tag as i64)
        .bind(b_id)
        .execute(app.db())
        .await
        .unwrap();
    let ra = app.rename(&a.session.access_token, "Twin").await;
    assert_eq!(ra.status, 200);
    assert_eq!(ra.json["name_tag"], json!(a.profile.name_tag));
    let rb = app.rename(&b.session.access_token, "TWIN").await;
    assert_eq!(rb.status, 200);
    assert_ne!(rb.json["name_tag"], ra.json["name_tag"]);

    // Every tag of a name taken: 409 name_unavailable.
    let mut tx = app.db().begin().await.unwrap();
    for tag in 0..=9_999i64 {
        sqlx::query(
            "INSERT OR IGNORE INTO accounts (display_name, tag, created_at, last_seen) VALUES ('Crowded', ?, 0, 0)",
        )
        .bind(tag)
        .execute(&mut *tx)
        .await
        .unwrap();
    }
    tx.commit().await.unwrap();
    let c = app.create_device().await;
    assert_error(
        &app.rename(&c.session.access_token, "crowded").await,
        409,
        "name_unavailable",
    );
    // Direct: a rename that must move tags still finds a free one.
    sqlx::query("DELETE FROM accounts WHERE display_name = 'Crowded' AND tag = 4242")
        .execute(app.db())
        .await
        .unwrap();
    let acc = accounts::rename(app.db(), a_id, "Crowded", T0, None)
        .await
        .unwrap();
    assert_eq!((acc.display_name.as_str(), acc.tag), ("Crowded", 4242));
}

async fn count(app: &common::TestApp, sql: &'static str, id: i64) -> i64 {
    sqlx::query_scalar::<_, i64>(sql)
        .bind(id)
        .fetch_one(app.db())
        .await
        .unwrap()
}

#[tokio::test]
async fn delete_account_removes_everything() {
    let app = common::app().await;
    let d = app.create_device().await;
    let keep = app.create_device().await;
    let id: i64 = d.session.account_id.parse().unwrap();
    app.login(&d.session.account_id, &d.device_secret).await;
    app.refresh(&d.session.refresh_token).await;
    let tokens: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM refresh_tokens WHERE account_id = ?")
            .bind(id)
            .fetch_one(app.db())
            .await
            .unwrap();
    assert_eq!(tokens, 3);

    let r = app
        .call(
            "DELETE",
            "/api/v1/account",
            Some(&d.session.access_token),
            None,
        )
        .await;
    assert_eq!(r.status, 204, "{:?}", r.json);

    assert_eq!(
        count(&app, "SELECT COUNT(*) FROM accounts WHERE id = ?", id).await,
        0
    );
    assert_eq!(
        count(
            &app,
            "SELECT COUNT(*) FROM refresh_tokens WHERE account_id = ?",
            id
        )
        .await,
        0
    );
    let (actor, action, target, detail): (String, String, String, String) = sqlx::query_as(
        "SELECT actor, action, target, detail FROM admin_log WHERE action = 'account_delete'",
    )
    .fetch_one(app.db())
    .await
    .unwrap();
    assert_eq!(
        (actor.as_str(), action.as_str()),
        ("self", "account_delete")
    );
    assert_eq!(target, id.to_string());
    assert_eq!(detail, "refresh_tokens=3");
    assert!(!detail.contains(&d.profile.display_name));

    // Nothing of the account works any more.
    assert_error(&app.me(&d.session.access_token).await, 401, "token_revoked");
    assert_error(
        &app.refresh(&d.session.refresh_token).await,
        401,
        "invalid_token",
    );
    assert_error(
        &app.login(&d.session.account_id, &d.device_secret).await,
        401,
        "invalid_credentials",
    );
    let r = app
        .call(
            "DELETE",
            "/api/v1/account",
            Some(&d.session.access_token),
            None,
        )
        .await;
    assert_error(&r, 401, "token_revoked");
    // Other accounts are untouched.
    assert_eq!(app.me(&keep.session.access_token).await.status, 200);
}

#[tokio::test]
async fn bans_block_sign_in_refresh_and_me_until_they_end() {
    let app = common::app().await;
    let d = app.create_device().await;
    let id: i64 = d.session.account_id.parse().unwrap();
    let until = T0 + 7 * DAY;
    assert!(accounts::set_ban(app.db(), id, Some(until)).await.unwrap());

    let r = app.me(&d.session.access_token).await;
    assert_error(&r, 403, "banned");
    assert_eq!(r.json["banned_until"], json!(until));
    let r = app.refresh(&d.session.refresh_token).await;
    assert_error(&r, 403, "banned");
    assert_eq!(r.json["banned_until"], json!(until));
    let r = app.login(&d.session.account_id, &d.device_secret).await;
    assert_error(&r, 403, "banned");
    assert_eq!(r.json["banned_until"], json!(until));

    // After the ban: the same refresh token (not consumed while banned) works.
    app.clock.set(until);
    let r = app.refresh(&d.session.refresh_token).await;
    assert_eq!(r.status, 200, "{:?}", r.json);
    let token = r.json["access_token"].as_str().unwrap().to_string();
    assert_eq!(app.me(&token).await.status, 200);

    // A banned account can still delete itself.
    assert!(accounts::set_ban(app.db(), id, Some(until + 30 * DAY))
        .await
        .unwrap());
    let r = app
        .call("DELETE", "/api/v1/account", Some(&token), None)
        .await;
    assert_eq!(r.status, 204);
}
