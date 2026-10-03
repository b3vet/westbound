//! Crew invites (the owner's request "there is no way to invite my friends to my crew"):
//! a member invites a friend; the invitee lists, accepts (joins with the join-by-code
//! checks) or declines; renewal, expiry, the crew's pending cap, permissions, blocks, crew
//! full, already in a crew, disbanding, account deletion, the live `lobby_event.crew_invite`
//! (protocol 2 sessions only), crew member presence for members, and the housekeeping pass.
//! In-process against the router with a manual clock (tests/common).

mod common;

use common::*;
use protocol::{LobbyEvent, ServerMsg};
use serde_json::{json, Value};
use westbound_server::clock::Clock;
use westbound_server::sessions::SessionHandle;

struct P {
    id: i64,
    token: String,
    name: String,
}

async fn player(app: &TestApp) -> P {
    let (id, token) = app.account().await;
    let name = app.me(&token).await.json["full_name"]
        .as_str()
        .unwrap()
        .to_string();
    P { id, token, name }
}

async fn post(app: &TestApp, p: &P, path: &str, body: Option<Value>) -> Resp {
    app.call("POST", path, Some(&p.token), body).await
}

async fn get(app: &TestApp, p: &P, path: &str) -> Resp {
    app.call("GET", path, Some(&p.token), None).await
}

async fn befriend(app: &TestApp, a: &P, b: &P) {
    let r = post(
        app,
        a,
        "/api/v1/friends/requests",
        Some(json!({ "full_name": b.name })),
    )
    .await;
    assert_eq!(r.status, 201, "{:?}", r.json);
    let id = r.json["request_id"].as_str().unwrap().to_string();
    let r = post(
        app,
        b,
        &format!("/api/v1/friends/requests/{id}/accept"),
        None,
    )
    .await;
    assert_eq!(r.status, 200, "{:?}", r.json);
}

/// `owner` creates a crew; its id and invite code.
async fn crew(app: &TestApp, owner: &P, name: &str, tag: &str) -> (String, String) {
    let r = post(
        app,
        owner,
        "/api/v1/crews",
        Some(json!({ "name": name, "tag": tag })),
    )
    .await;
    assert_eq!(r.status, 201, "{:?}", r.json);
    (
        r.json["crew_id"].as_str().unwrap().to_string(),
        r.json["invite_code"].as_str().unwrap().to_string(),
    )
}

async fn invite(app: &TestApp, from: &P, crew_id: &str, to: &P) -> Resp {
    post(
        app,
        from,
        &format!("/api/v1/crews/{crew_id}/invites"),
        Some(json!({ "account_id": to.id.to_string() })),
    )
    .await
}

async fn my_invites(app: &TestApp, p: &P) -> Vec<Value> {
    let r = get(app, p, "/api/v1/crews/invites").await;
    assert_eq!(r.status, 200, "{:?}", r.json);
    r.json["invites"].as_array().unwrap().clone()
}

async fn rows(app: &TestApp) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM crew_invites")
        .fetch_one(app.db())
        .await
        .unwrap()
}

#[tokio::test]
async fn invite_list_accept_and_decline() {
    let app = app().await;
    let (a, b, c) = (player(&app).await, player(&app).await, player(&app).await);
    befriend(&app, &a, &b).await;
    befriend(&app, &a, &c).await;
    let (crew_id, _) = crew(&app, &a, "Night Riders", "NR").await;

    let r = invite(&app, &a, &crew_id, &b).await;
    assert_eq!(r.status, 201, "{:?}", r.json);
    assert_eq!(r.json["player"]["account_id"], b.id.to_string());
    assert_eq!(r.json["from"]["account_id"], a.id.to_string());
    assert_eq!(r.json["expires_at"], T0 + 168 * 3_600);
    // A second invite renews the first (200, a later expiry).
    app.clock.advance(60);
    let again = invite(&app, &a, &crew_id, &b).await;
    assert_eq!(again.status, 200, "{:?}", again.json);
    assert_eq!(again.json["invite_id"], r.json["invite_id"]);
    assert_eq!(again.json["expires_at"], T0 + 60 + 168 * 3_600);
    assert_eq!(invite(&app, &a, &crew_id, &c).await.status, 201);

    // The crew's waiting invites, for members.
    let sent = get(&app, &a, &format!("/api/v1/crews/{crew_id}/invites")).await;
    assert_eq!(sent.status, 200);
    assert_eq!(sent.json["invites"].as_array().unwrap().len(), 2);
    assert_error(
        &get(&app, &b, &format!("/api/v1/crews/{crew_id}/invites")).await,
        404,
        "not_in_crew",
    );

    // B's list: the crew, who sent it, the size.
    let list = my_invites(&app, &b).await;
    assert_eq!(list.len(), 1);
    let inv = &list[0];
    assert_eq!(inv["crew_id"], crew_id);
    assert_eq!(inv["crew_name"], "Night Riders");
    assert_eq!(inv["crew_tag"], "NR");
    assert_eq!(inv["member_count"], 1);
    assert_eq!(inv["max_members"], 16);
    assert_eq!(inv["from"]["full_name"], a.name);
    let b_invite = inv["invite_id"].as_str().unwrap().to_string();

    // Someone else can't answer B's invite.
    assert_error(
        &post(
            &app,
            &c,
            &format!("/api/v1/crews/invites/{b_invite}/accept"),
            None,
        )
        .await,
        404,
        "invite_not_found",
    );
    let r = post(
        &app,
        &b,
        &format!("/api/v1/crews/invites/{b_invite}/accept"),
        None,
    )
    .await;
    assert_eq!(r.status, 200, "{:?}", r.json);
    assert_eq!(r.json["member_count"], 2);
    assert_eq!(r.json["your_role"], "member");
    assert!(my_invites(&app, &b).await.is_empty(), "accepting clears it");
    assert_error(
        &post(
            &app,
            &b,
            &format!("/api/v1/crews/invites/{b_invite}/accept"),
            None,
        )
        .await,
        404,
        "invite_not_found",
    );

    // C declines.
    let c_invite = my_invites(&app, &c).await[0]["invite_id"]
        .as_str()
        .unwrap()
        .to_string();
    let r = post(
        &app,
        &c,
        &format!("/api/v1/crews/invites/{c_invite}/decline"),
        None,
    )
    .await;
    assert_eq!(r.status, 204);
    assert!(my_invites(&app, &c).await.is_empty());
    assert_error(
        &post(
            &app,
            &c,
            &format!("/api/v1/crews/invites/{c_invite}/decline"),
            None,
        )
        .await,
        404,
        "invite_not_found",
    );
    assert_error(
        &post(&app, &c, "/api/v1/crews/invites/x1/decline", None).await,
        404,
        "invite_not_found",
    );
    assert_eq!(rows(&app).await, 0);
}

#[tokio::test]
async fn any_member_invites_friends_only() {
    let app = app().await;
    let (a, b, c, d) = (
        player(&app).await,
        player(&app).await,
        player(&app).await,
        player(&app).await,
    );
    let (crew_id, code) = crew(&app, &a, "Day Riders", "DR").await;
    // B joins by code; B is a plain member and may invite their own friend C (every member
    // sees the code, so an invite gives no new power).
    let r = post(
        &app,
        &b,
        "/api/v1/crews/join",
        Some(json!({ "invite_code": code })),
    )
    .await;
    assert_eq!(r.status, 200, "{:?}", r.json);
    befriend(&app, &b, &c).await;
    assert_eq!(invite(&app, &b, &crew_id, &c).await.status, 201);
    // Not a friend of the sender.
    assert_error(&invite(&app, &a, &crew_id, &c).await, 403, "not_friends");
    // Not a member of that crew.
    befriend(&app, &d, &c).await;
    assert_error(&invite(&app, &d, &crew_id, &c).await, 404, "not_in_crew");
    // Yourself, a member, an unknown player, a bad body.
    let self_invite = post(
        &app,
        &a,
        &format!("/api/v1/crews/{crew_id}/invites"),
        Some(json!({ "account_id": a.id.to_string() })),
    )
    .await;
    assert_error(&self_invite, 400, "cannot_invite_self");
    befriend(&app, &a, &b).await;
    assert_error(&invite(&app, &a, &crew_id, &b).await, 409, "already_member");
    let unknown = post(
        &app,
        &a,
        &format!("/api/v1/crews/{crew_id}/invites"),
        Some(json!({ "account_id": "999999" })),
    )
    .await;
    assert_error(&unknown, 404, "player_not_found");
    let bad = post(
        &app,
        &a,
        &format!("/api/v1/crews/{crew_id}/invites"),
        Some(json!({ "account_id": "x" })),
    )
    .await;
    assert_error(&bad, 400, "invalid_body");
}

#[tokio::test]
async fn blocks_refuse_and_hide_invites() {
    let app = app().await;
    let (a, b, c) = (player(&app).await, player(&app).await, player(&app).await);
    befriend(&app, &a, &b).await;
    befriend(&app, &a, &c).await;
    let (crew_id, _) = crew(&app, &a, "Blockers", "BLK").await;
    assert_eq!(invite(&app, &a, &crew_id, &b).await.status, 201);
    let id = my_invites(&app, &b).await[0]["invite_id"]
        .as_str()
        .unwrap()
        .to_string();
    // B blocks A: the invite is gone from B's list and can't be accepted; A can't invite B
    // again (blocking ends the friendship; the answer does not say which).
    let r = post(
        &app,
        &b,
        "/api/v1/blocks",
        Some(json!({ "account_id": a.id.to_string() })),
    )
    .await;
    assert_eq!(r.status, 201, "{:?}", r.json);
    assert!(my_invites(&app, &b).await.is_empty());
    assert_error(
        &post(
            &app,
            &b,
            &format!("/api/v1/crews/invites/{id}/accept"),
            None,
        )
        .await,
        404,
        "invite_not_found",
    );
    assert_error(&invite(&app, &a, &crew_id, &b).await, 403, "not_friends");
    // A blocks C after the invite: hidden too.
    assert_eq!(invite(&app, &a, &crew_id, &c).await.status, 201);
    let r = post(
        &app,
        &a,
        "/api/v1/blocks",
        Some(json!({ "account_id": c.id.to_string() })),
    )
    .await;
    assert_eq!(r.status, 201);
    assert!(my_invites(&app, &c).await.is_empty());
}

#[tokio::test]
async fn crew_full_already_in_a_crew_and_the_pending_cap() {
    let app = app_with(|c| {
        c.social.crew_max_members = 2;
        c.social.crew_max_pending_invites = 2;
    })
    .await;
    let (a, b, c, d, e) = (
        player(&app).await,
        player(&app).await,
        player(&app).await,
        player(&app).await,
        player(&app).await,
    );
    for p in [&b, &c, &d, &e] {
        befriend(&app, &a, p).await;
    }
    let (crew_id, _) = crew(&app, &a, "Pair Crew", "PAIR").await;
    assert_eq!(invite(&app, &a, &crew_id, &b).await.status, 201);
    assert_eq!(invite(&app, &a, &crew_id, &c).await.status, 201);
    // Two waiting: a third is refused; renewing one of the two is not.
    assert_error(
        &invite(&app, &a, &crew_id, &d).await,
        409,
        "crew_invites_limit",
    );
    assert_eq!(invite(&app, &a, &crew_id, &c).await.status, 200);
    // B accepts: the crew is full (2); C's accept and new invites are refused.
    let bid = my_invites(&app, &b).await[0]["invite_id"]
        .as_str()
        .unwrap()
        .to_string();
    let r = post(
        &app,
        &b,
        &format!("/api/v1/crews/invites/{bid}/accept"),
        None,
    )
    .await;
    assert_eq!(r.status, 200, "{:?}", r.json);
    let cid = my_invites(&app, &c).await[0]["invite_id"]
        .as_str()
        .unwrap()
        .to_string();
    assert_error(
        &post(
            &app,
            &c,
            &format!("/api/v1/crews/invites/{cid}/accept"),
            None,
        )
        .await,
        409,
        "crew_full",
    );
    assert_error(&invite(&app, &a, &crew_id, &d).await, 409, "crew_full");
    // E is in another crew: invited all the same, accepting asks them to leave first.
    let (_, _) = crew(&app, &e, "Other Crew", "OTH").await;
    let r = post(
        &app,
        &a,
        &format!("/api/v1/crews/{crew_id}/kick"),
        Some(json!({ "account_id": b.id.to_string() })),
    )
    .await;
    assert_eq!(r.status, 200);
    assert_eq!(invite(&app, &a, &crew_id, &e).await.status, 201);
    let eid = my_invites(&app, &e).await[0]["invite_id"]
        .as_str()
        .unwrap()
        .to_string();
    assert_error(
        &post(
            &app,
            &e,
            &format!("/api/v1/crews/invites/{eid}/accept"),
            None,
        )
        .await,
        409,
        "already_in_crew",
    );
    assert_eq!(my_invites(&app, &e).await.len(), 1, "still waiting");
}

#[tokio::test]
async fn invites_expire_and_housekeeping_deletes_them() {
    let app = app_with(|c| {
        long_tokens(c);
        c.social.crew_invite_ttl_hours = 1;
    })
    .await;
    let (a, b, c) = (player(&app).await, player(&app).await, player(&app).await);
    befriend(&app, &a, &b).await;
    befriend(&app, &a, &c).await;
    let (crew_id, _) = crew(&app, &a, "Short Lived", "SL").await;
    assert_eq!(invite(&app, &a, &crew_id, &b).await.status, 201);
    let id = my_invites(&app, &b).await[0]["invite_id"]
        .as_str()
        .unwrap()
        .to_string();
    app.clock.advance(1_800);
    assert_eq!(invite(&app, &a, &crew_id, &c).await.status, 201);
    app.clock.advance(1_800);
    // B's is an hour old: gone from every read, not acceptable.
    assert!(my_invites(&app, &b).await.is_empty());
    assert_error(
        &post(
            &app,
            &b,
            &format!("/api/v1/crews/invites/{id}/accept"),
            None,
        )
        .await,
        404,
        "invite_not_found",
    );
    let sent = get(&app, &a, &format!("/api/v1/crews/{crew_id}/invites")).await;
    assert_eq!(sent.json["invites"].as_array().unwrap().len(), 1);
    // The daily pass deletes the expired row and keeps the live one.
    assert_eq!(rows(&app).await, 2);
    let r = westbound_server::housekeeping::run_daily(app.db(), &app.state.config, app.clock.now())
        .await;
    assert_eq!(r.crew_invites, 1, "{r:?}");
    assert!(r.summary().contains("crew_invites=1"));
    assert_eq!(rows(&app).await, 1);
    // An expired invite can be sent again.
    assert_eq!(invite(&app, &a, &crew_id, &b).await.status, 201);
}

#[tokio::test]
async fn joining_disbanding_and_account_deletion_remove_invites() {
    let app = app().await;
    let (a, b, c, d) = (
        player(&app).await,
        player(&app).await,
        player(&app).await,
        player(&app).await,
    );
    for p in [&b, &c, &d] {
        befriend(&app, &a, p).await;
    }
    let (crew_id, code) = crew(&app, &a, "Removers", "RMV").await;
    assert_eq!(invite(&app, &a, &crew_id, &b).await.status, 201);
    assert_eq!(invite(&app, &a, &crew_id, &c).await.status, 201);
    assert_eq!(invite(&app, &a, &crew_id, &d).await.status, 201);
    // B joins by code instead: the invite to that crew goes.
    let r = post(
        &app,
        &b,
        "/api/v1/crews/join",
        Some(json!({ "invite_code": code })),
    )
    .await;
    assert_eq!(r.status, 200);
    assert!(my_invites(&app, &b).await.is_empty());
    assert_eq!(rows(&app).await, 2);
    // C deletes their account: the invite to them goes.
    let r = app
        .call("DELETE", "/api/v1/account", Some(&c.token), None)
        .await;
    assert_eq!(r.status, 204, "{:?}", r.json);
    assert_eq!(rows(&app).await, 1);
    // The sender A deletes their account: the invites they sent go (the crew passes to B).
    let (crew2, _) = crew(&app, &d, "Second Crew", "SEC").await;
    befriend(&app, &d, &b).await;
    let r = post(&app, &b, &format!("/api/v1/crews/{crew_id}/leave"), None).await;
    assert_eq!(r.status, 200);
    assert_eq!(invite(&app, &d, &crew2, &b).await.status, 201);
    assert_eq!(rows(&app).await, 2);
    let r = app
        .call("DELETE", "/api/v1/account", Some(&a.token), None)
        .await;
    assert_eq!(r.status, 204, "{:?}", r.json);
    assert_eq!(rows(&app).await, 1, "A's invite to D went with A");
    let detail: String = sqlx::query_scalar(
        "SELECT detail FROM admin_log WHERE action = 'account_delete' ORDER BY id DESC LIMIT 1",
    )
    .fetch_one(app.db())
    .await
    .unwrap();
    assert!(detail.contains("crew_invites=1"), "{detail}");
    // Disbanding deletes the crew's invites.
    let r = app
        .call(
            "DELETE",
            &format!("/api/v1/crews/{crew2}"),
            Some(&d.token),
            None,
        )
        .await;
    assert_eq!(r.status, 204);
    assert_eq!(rows(&app).await, 0);
}

/// A live session for `p` with protocol `version`: its outbound queue.
fn session(
    app: &TestApp,
    p: &P,
    version: u16,
) -> tokio::sync::mpsc::Receiver<axum::extract::ws::Message> {
    let (tx, rx) = tokio::sync::mpsc::channel(8);
    let (h, kick) = SessionHandle::new(
        app.state.sessions.next_session_id(),
        protocol::AccountId(p.id as u64),
        0,
        tx,
    );
    drop(kick);
    app.state.sessions.register(h.with_protocol(version));
    rx
}

fn lobby_events(
    rx: &mut tokio::sync::mpsc::Receiver<axum::extract::ws::Message>,
) -> Vec<LobbyEvent> {
    let mut out = Vec::new();
    while let Ok(m) = rx.try_recv() {
        if let axum::extract::ws::Message::Binary(b) = m {
            for msg in protocol::decode_server_frame(&b).unwrap() {
                if let ServerMsg::LobbyEvent(e) = msg {
                    out.push(e);
                }
            }
        }
    }
    out
}

#[tokio::test]
async fn an_online_invitee_hears_at_once_and_members_see_presence() {
    let app = app().await;
    let (a, b, c) = (player(&app).await, player(&app).await, player(&app).await);
    befriend(&app, &a, &b).await;
    befriend(&app, &a, &c).await;
    let (crew_id, _) = crew(&app, &a, "Live Wire", "LIVE").await;
    let mut b_rx = session(&app, &b, protocol::PROTOCOL_VERSION);
    let mut c_rx = session(&app, &c, 1);
    let r = invite(&app, &a, &crew_id, &b).await;
    assert_eq!(r.status, 201);
    let ev = lobby_events(&mut b_rx);
    assert_eq!(ev.len(), 1, "{ev:?}");
    let LobbyEvent::CrewInvite(inv) = &ev[0] else {
        panic!("{ev:?}");
    };
    assert_eq!(
        inv.invite_id.0.to_string(),
        r.json["invite_id"].as_str().unwrap()
    );
    assert_eq!(inv.crew_tag.as_str(), "LIVE");
    assert_eq!(inv.crew_name.0, "Live Wire");
    assert_eq!(inv.from.account_id.0, a.id as u64);
    assert_eq!(inv.expires_in_s, 168 * 3_600);
    // A protocol 1 client never gets the new event (it could not decode it); the invite
    // waits in its list.
    assert_eq!(invite(&app, &a, &crew_id, &c).await.status, 201);
    assert!(lobby_events(&mut c_rx).is_empty());
    assert_eq!(my_invites(&app, &c).await.len(), 1);
    // B joins; members see the crew's presence (B online), others see none.
    let id = r.json["invite_id"].as_str().unwrap();
    let r = post(
        &app,
        &b,
        &format!("/api/v1/crews/invites/{id}/accept"),
        None,
    )
    .await;
    assert_eq!(r.status, 200);
    let mine = get(&app, &a, "/api/v1/crews/mine").await.json;
    let status = |v: &Value, who: &P| {
        v["members"]
            .as_array()
            .unwrap()
            .iter()
            .find(|m| m["account_id"].as_str().and_then(|s| s.parse::<i64>().ok()) == Some(who.id))
            .map(|m| m["status"].clone())
            .unwrap()
    };
    assert_eq!(status(&mine, &b), "online");
    assert_eq!(status(&mine, &a), "offline");
    let other = get(&app, &c, &format!("/api/v1/crews/{crew_id}"))
        .await
        .json;
    assert_eq!(status(&other, &b), Value::Null);
}
