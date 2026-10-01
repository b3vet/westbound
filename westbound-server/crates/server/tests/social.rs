//! Social API (N9.1): friend requests and the friends list, caps, blocking semantics,
//! presence over HTTP, crews (roles, caps, invite codes, the profanity filter), the friends
//! leaderboard view, crew tags and Loop crew sums on the boards, the account-deletion
//! cascade, reports and their rate limit, the social rate limit, and the admin commands.
//! In-process against the router with a manual clock (tests/common). Presence over a real
//! WebSocket is in tests/presence.rs.

mod common;

use common::*;
use serde_json::{json, Value};
use westbound_server::admin;
use westbound_server::leaderboards::{MultiplayerRun, RoomKind};
use westbound_server::presence::RoomPresence;
use westbound_server::sessions::SessionHandle;
use westbound_server::social;

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

async fn request(app: &TestApp, from: &P, full_name: &str) -> Resp {
    app.call(
        "POST",
        "/api/v1/friends/requests",
        Some(&from.token),
        Some(json!({ "full_name": full_name })),
    )
    .await
}

async fn post(app: &TestApp, p: &P, path: &str, body: Option<Value>) -> Resp {
    app.call("POST", path, Some(&p.token), body).await
}

async fn get(app: &TestApp, p: &P, path: &str) -> Resp {
    app.call("GET", path, Some(&p.token), None).await
}

async fn delete(app: &TestApp, p: &P, path: &str) -> Resp {
    app.call("DELETE", path, Some(&p.token), None).await
}

/// `a` asks, `b` accepts.
async fn befriend(app: &TestApp, a: &P, b: &P) {
    let r = request(app, a, &b.name).await;
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

async fn friends(app: &TestApp, p: &P) -> Value {
    let r = get(app, p, "/api/v1/friends").await;
    assert_eq!(r.status, 200, "{:?}", r.json);
    r.json
}

/// A decimal-string id.
fn id_of(v: &Value) -> i64 {
    v.as_str().unwrap().parse().unwrap()
}

/// The `account_id`s of a list in a friends body.
fn ids(body: &Value, list: &str) -> Vec<i64> {
    body[list]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["account_id"].as_str().unwrap().parse().unwrap())
        .collect()
}

/// `from` reports `to` (context `{"source": "room"}`).
async fn report(app: &TestApp, from: &P, to: &P, reason: &str) -> Resp {
    post(
        app,
        from,
        "/api/v1/reports",
        Some(
            json!({"target_account_id": to.id.to_string(), "reason": reason,
                    "context": {"source": "room"}}),
        ),
    )
    .await
}

async fn count(app: &TestApp, sql: &'static str, id: i64) -> i64 {
    sqlx::query_scalar(sql)
        .bind(id)
        .fetch_one(app.db())
        .await
        .unwrap()
}

// ---------------------------------------------------------------------------------------------
// Friends
// ---------------------------------------------------------------------------------------------

#[tokio::test]
async fn friend_requests_accept_decline_cancel_remove() {
    let app = app().await;
    let (a, b, c) = (player(&app).await, player(&app).await, player(&app).await);

    // A asks B (the name matches case-insensitively).
    let r = request(&app, &a, &b.name.to_lowercase()).await;
    assert_eq!(r.status, 201, "{:?}", r.json);
    assert_eq!(r.json["status"], "pending");
    assert_eq!(r.json["player"]["account_id"], b.id.to_string());
    assert_eq!(r.json["player"]["full_name"], b.name);
    let req = r.json["request_id"].as_str().unwrap().to_string();
    let fa = friends(&app, &a).await;
    assert_eq!(ids(&fa, "outgoing"), vec![b.id]);
    assert!(ids(&fa, "friends").is_empty() && ids(&fa, "incoming").is_empty());
    assert_eq!(fa["outgoing"][0]["request_id"], req);
    assert_eq!(fa["outgoing"][0]["status"], "offline");
    assert_eq!(fa["max_friends"], 100);
    let fb = friends(&app, &b).await;
    assert_eq!(ids(&fb, "incoming"), vec![a.id]);
    assert_eq!(fb["incoming"][0]["created_at"], T0);

    // Request errors.
    assert_error(&request(&app, &a, &b.name).await, 409, "request_exists");
    assert_error(
        &request(&app, &a, "no hash").await,
        400,
        "invalid_full_name",
    );
    assert_error(
        &request(&app, &a, "Nobody#0000").await,
        404,
        "player_not_found",
    );
    assert_error(&request(&app, &a, &a.name).await, 400, "cannot_friend_self");
    let r = app
        .call(
            "POST",
            "/api/v1/friends/requests",
            None,
            Some(json!({"full_name": b.name})),
        )
        .await;
    assert_error(&r, 401, "unauthorized");
    let r = post(
        &app,
        &a,
        "/api/v1/friends/requests",
        Some(json!({"full_name": b.name, "x": 1})),
    )
    .await;
    assert_error(&r, 400, "invalid_body");

    // Accept: only the recipient, only a pending request.
    let accept = |id: &str| format!("/api/v1/friends/requests/{id}/accept");
    assert_error(
        &post(&app, &a, &accept(&req), None).await,
        404,
        "request_not_found",
    );
    assert_error(
        &post(&app, &c, &accept(&req), None).await,
        404,
        "request_not_found",
    );
    assert_error(
        &post(&app, &b, &accept("999"), None).await,
        404,
        "request_not_found",
    );
    assert_error(
        &post(&app, &b, &accept("x"), None).await,
        404,
        "request_not_found",
    );
    app.clock.advance(60);
    let r = post(&app, &b, &accept(&req), None).await;
    assert_eq!(r.status, 200, "{:?}", r.json);
    assert_eq!(r.json["status"], "accepted");
    assert_eq!(r.json["player"]["account_id"], a.id.to_string());
    assert_error(
        &post(&app, &b, &accept(&req), None).await,
        404,
        "request_not_found",
    );
    let fa = friends(&app, &a).await;
    assert_eq!(ids(&fa, "friends"), vec![b.id]);
    assert!(ids(&fa, "outgoing").is_empty());
    assert_eq!(fa["friends"][0]["since"], T0 + 60);
    assert_eq!(fa["friends"][0]["status"], "offline");
    assert!(fa["friends"][0]["room_id"].is_null());
    assert_eq!(ids(&friends(&app, &b).await, "friends"), vec![a.id]);
    assert_error(&request(&app, &a, &b.name).await, 409, "already_friends");
    assert_error(&request(&app, &b, &a.name).await, 409, "already_friends");

    // Decline (recipient) and cancel (requester).
    let decline = |id: &str| format!("/api/v1/friends/requests/{id}/decline");
    let r = request(&app, &c, &a.name).await;
    let id = r.json["request_id"].as_str().unwrap().to_string();
    assert_eq!(post(&app, &a, &decline(&id), None).await.status, 204);
    assert_error(
        &post(&app, &a, &decline(&id), None).await,
        404,
        "request_not_found",
    );
    let r = request(&app, &a, &c.name).await;
    let id = r.json["request_id"].as_str().unwrap().to_string();
    assert_error(
        &post(&app, &b, &decline(&id), None).await,
        404,
        "request_not_found",
    );
    assert_eq!(post(&app, &a, &decline(&id), None).await.status, 204);
    assert!(ids(&friends(&app, &c).await, "incoming").is_empty());

    // Asking someone who already asked you accepts their request.
    request(&app, &c, &a.name).await;
    let r = request(&app, &a, &c.name).await;
    assert_eq!(r.status, 200, "{:?}", r.json);
    assert_eq!(r.json["status"], "accepted");
    let mut fa = ids(&friends(&app, &a).await, "friends");
    fa.sort_unstable();
    let mut want = vec![b.id, c.id];
    want.sort_unstable();
    assert_eq!(fa, want);

    // Remove.
    let r = delete(&app, &a, &format!("/api/v1/friends/{}", b.id)).await;
    assert_eq!(r.status, 204);
    assert_error(
        &delete(&app, &b, &format!("/api/v1/friends/{}", a.id)).await,
        404,
        "friend_not_found",
    );
    assert_error(
        &delete(&app, &a, "/api/v1/friends/abc").await,
        404,
        "friend_not_found",
    );
    assert_eq!(ids(&friends(&app, &a).await, "friends"), vec![c.id]);
    assert!(ids(&friends(&app, &b).await, "friends").is_empty());
    // Removing also cancels a pending request, either way.
    request(&app, &b, &a.name).await;
    assert_eq!(
        delete(&app, &a, &format!("/api/v1/friends/{}", b.id))
            .await
            .status,
        204
    );
    assert!(ids(&friends(&app, &b).await, "outgoing").is_empty());
    // The friends routes need a token.
    assert_error(
        &app.call("GET", "/api/v1/friends", None, None).await,
        401,
        "unauthorized",
    );
}

#[tokio::test]
async fn friend_caps() {
    let app = app_with(|c| {
        c.social.max_friends = 2;
        c.social.max_outgoing_requests = 2;
        c.social.max_incoming_requests = 2;
    })
    .await;
    let mut ps = Vec::new();
    for _ in 0..7 {
        ps.push(player(&app).await);
    }
    // Outgoing: two pending at most.
    assert_eq!(request(&app, &ps[0], &ps[1].name).await.status, 201);
    assert_eq!(request(&app, &ps[0], &ps[2].name).await.status, 201);
    assert_error(
        &request(&app, &ps[0], &ps[3].name).await,
        409,
        "requests_limit",
    );
    // Incoming: two pending at most.
    assert_eq!(request(&app, &ps[4], &ps[3].name).await.status, 201);
    assert_eq!(request(&app, &ps[5], &ps[3].name).await.status, 201);
    assert_error(
        &request(&app, &ps[6], &ps[3].name).await,
        409,
        "target_requests_limit",
    );
    // Friends: 0 ↔ 1 and 0 ↔ 2 fill 0's list.
    let f = friends(&app, &ps[1]).await;
    let accept = |id: &Value| format!("/api/v1/friends/requests/{}/accept", id.as_str().unwrap());
    assert_eq!(
        post(&app, &ps[1], &accept(&f["incoming"][0]["request_id"]), None)
            .await
            .status,
        200
    );
    let f = friends(&app, &ps[2]).await;
    assert_eq!(
        post(&app, &ps[2], &accept(&f["incoming"][0]["request_id"]), None)
            .await
            .status,
        200
    );
    assert_error(
        &request(&app, &ps[0], &ps[6].name).await,
        409,
        "friends_limit",
    );
    assert_error(
        &request(&app, &ps[6], &ps[0].name).await,
        409,
        "target_friends_limit",
    );
    // A request made before the list filled cannot be accepted after.
    let r = request(&app, &ps[5], &ps[1].name).await;
    assert_eq!(r.status, 201);
    let r = request(&app, &ps[3], &ps[1].name).await;
    assert_eq!(r.status, 201, "{:?}", r.json);
    // 1 now accepts 5: 1 has one friend (0), so this fills 1's list.
    let f = friends(&app, &ps[1]).await;
    let from5 = f["incoming"]
        .as_array()
        .unwrap()
        .iter()
        .find(|e| id_of(&e["account_id"]) == ps[5].id)
        .unwrap()["request_id"]
        .clone();
    let from3 = f["incoming"]
        .as_array()
        .unwrap()
        .iter()
        .find(|e| id_of(&e["account_id"]) == ps[3].id)
        .unwrap()["request_id"]
        .clone();
    assert_eq!(post(&app, &ps[1], &accept(&from5), None).await.status, 200);
    assert_error(
        &post(&app, &ps[1], &accept(&from3), None).await,
        409,
        "friends_limit",
    );
}

// ---------------------------------------------------------------------------------------------
// Blocks
// ---------------------------------------------------------------------------------------------

#[tokio::test]
async fn blocking_semantics() {
    let app = app().await;
    let (a, b, c) = (player(&app).await, player(&app).await, player(&app).await);
    befriend(&app, &a, &b).await;
    request(&app, &c, &a.name).await;

    // A blocks B: the friendship goes.
    let r = post(
        &app,
        &a,
        "/api/v1/blocks",
        Some(json!({"account_id": b.id.to_string()})),
    )
    .await;
    assert_eq!(r.status, 201, "{:?}", r.json);
    assert_eq!(r.json["account_id"], b.id.to_string());
    assert_eq!(r.json["blocked_at"], T0);
    assert!(ids(&friends(&app, &a).await, "friends").is_empty());
    assert!(ids(&friends(&app, &b).await, "friends").is_empty());
    // Blocking again is fine (200).
    let r = post(
        &app,
        &a,
        "/api/v1/blocks",
        Some(json!({"account_id": b.id.to_string()})),
    )
    .await;
    assert_eq!(r.status, 200);
    // Neither side can send a request, and the error is the unknown-name one.
    let unknown = request(&app, &b, "Nobody#0000").await;
    for r in [
        request(&app, &b, &a.name).await,
        request(&app, &a, &b.name).await,
    ] {
        assert_error(&r, 404, "player_not_found");
        assert_eq!(r.json, unknown.json, "blocking is not revealed");
    }
    // A pending request goes with a block.
    let r = post(
        &app,
        &a,
        "/api/v1/blocks",
        Some(json!({"account_id": c.id.to_string()})),
    )
    .await;
    assert_eq!(r.status, 201);
    assert!(ids(&friends(&app, &a).await, "incoming").is_empty());
    assert!(ids(&friends(&app, &c).await, "outgoing").is_empty());
    // The list, newest first.
    let r = get(&app, &a, "/api/v1/blocks").await;
    assert_eq!(r.status, 200);
    let listed: Vec<&str> = r.json["blocks"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["full_name"].as_str().unwrap())
        .collect();
    assert_eq!(listed, vec![c.name.as_str(), b.name.as_str()]);
    assert_eq!(r.json["max_blocks"], 500);
    assert!(get(&app, &b, "/api/v1/blocks").await.json["blocks"]
        .as_array()
        .unwrap()
        .is_empty());
    // is_blocked is symmetric; has_blocked is not.
    let mut conn = app.db().acquire().await.unwrap();
    assert!(social::is_blocked(&mut conn, a.id, b.id).await.unwrap());
    assert!(social::is_blocked(&mut conn, b.id, a.id).await.unwrap());
    assert!(social::has_blocked(&mut conn, a.id, b.id).await.unwrap());
    assert!(!social::has_blocked(&mut conn, b.id, a.id).await.unwrap());
    assert!(!social::is_blocked(&mut conn, b.id, c.id).await.unwrap());
    drop(conn);
    // Errors.
    let body = |id: String| Some(json!({ "account_id": id }));
    assert_error(
        &post(&app, &a, "/api/v1/blocks", body(a.id.to_string())).await,
        400,
        "cannot_block_self",
    );
    assert_error(
        &post(&app, &a, "/api/v1/blocks", body("99999".into())).await,
        404,
        "player_not_found",
    );
    assert_error(
        &post(&app, &a, "/api/v1/blocks", body("-1".into())).await,
        400,
        "invalid_body",
    );
    assert_error(
        &post(&app, &a, "/api/v1/blocks", Some(json!({"account_id": 5}))).await,
        400,
        "invalid_body",
    );
    // Unblock: only your own block.
    assert_error(
        &delete(&app, &b, &format!("/api/v1/blocks/{}", a.id)).await,
        404,
        "block_not_found",
    );
    assert_eq!(
        delete(&app, &a, &format!("/api/v1/blocks/{}", b.id))
            .await
            .status,
        204
    );
    assert_error(
        &delete(&app, &a, &format!("/api/v1/blocks/{}", b.id)).await,
        404,
        "block_not_found",
    );
    assert_eq!(request(&app, &b, &a.name).await.status, 201);
}

#[tokio::test]
async fn block_cap() {
    let app = app_with(|c| c.social.max_blocks = 1).await;
    let (a, b, c) = (player(&app).await, player(&app).await, player(&app).await);
    let body = |id: i64| Some(json!({ "account_id": id.to_string() }));
    assert_eq!(
        post(&app, &a, "/api/v1/blocks", body(b.id)).await.status,
        201
    );
    assert_error(
        &post(&app, &a, "/api/v1/blocks", body(c.id)).await,
        409,
        "blocks_limit",
    );
}

// ---------------------------------------------------------------------------------------------
// Presence over HTTP
// ---------------------------------------------------------------------------------------------

#[tokio::test]
async fn presence_over_http() {
    let app = app().await;
    let (a, b, c) = (player(&app).await, player(&app).await, player(&app).await);
    befriend(&app, &a, &b).await;
    befriend(&app, &a, &c).await;
    let r = get(&app, &a, "/api/v1/presence").await;
    assert_eq!(r.status, 200);
    let mut want = vec![
        json!({"account_id": b.id.to_string(), "status": "offline", "room_id": null, "joinable": false}),
        json!({"account_id": c.id.to_string(), "status": "offline", "room_id": null, "joinable": false}),
    ];
    assert_eq!(r.json["friends"], json!(want));
    // B has a live session (the gateway's registry is the source), then is in a room (N5).
    let (tx, _rx) = tokio::sync::mpsc::channel(4);
    let (h, _kick) = SessionHandle::new(
        app.state.sessions.next_session_id(),
        protocol::AccountId(b.id as u64),
        0,
        tx,
    );
    app.state.sessions.register(h.clone());
    want[0]["status"] = "online".into();
    assert_eq!(
        get(&app, &a, "/api/v1/presence").await.json["friends"],
        json!(want)
    );
    app.state.presence.set_room(
        protocol::AccountId(b.id as u64),
        Some(RoomPresence {
            room_id: 42,
            joinable: true,
        }),
    );
    want[0]["status"] = "in_room".into();
    want[0]["room_id"] = 42.into();
    want[0]["joinable"] = true.into();
    assert_eq!(
        get(&app, &a, "/api/v1/presence").await.json["friends"],
        json!(want)
    );
    // The friends list carries the same fields, in-room friends first.
    let f = friends(&app, &a).await;
    assert_eq!(ids(&f, "friends"), vec![b.id, c.id]);
    assert_eq!(f["friends"][0]["status"], "in_room");
    assert_eq!(f["friends"][0]["room_id"], 42);
    assert_eq!(f["friends"][1]["status"], "offline");
    // Strangers are not listed.
    assert!(get(&app, &b, "/api/v1/presence").await.json["friends"]
        .as_array()
        .unwrap()
        .iter()
        .all(|e| id_of(&e["account_id"]) != c.id));
    app.state
        .sessions
        .unregister(protocol::AccountId(b.id as u64), h.session_id);
    want[0] = json!({"account_id": b.id.to_string(), "status": "offline", "room_id": null, "joinable": false});
    assert_eq!(
        get(&app, &a, "/api/v1/presence").await.json["friends"],
        json!(want)
    );
    assert_error(
        &app.call("GET", "/api/v1/presence", None, None).await,
        401,
        "unauthorized",
    );
}

// ---------------------------------------------------------------------------------------------
// Friends leaderboard view
// ---------------------------------------------------------------------------------------------

#[tokio::test]
async fn friends_leaderboard_view() {
    let app = runs_app().await;
    let (a, b, c) = (player(&app).await, player(&app).await, player(&app).await);
    for (p, key, score) in [
        (&a, "fview-0001", 10_000),
        (&b, "fview-0002", 30_000),
        (&c, "fview-0003", 20_000),
    ] {
        app.submit_ok(&p.token, journey_run(key, score, 20_000.0))
            .await;
    }
    befriend(&app, &a, &b).await;
    let body = app.board_ok(Some(&a.token), "journey?view=friends").await;
    assert_eq!(body["friends_available"], true);
    assert_eq!(
        ranking(&body),
        vec![(b.id.to_string(), 30_000), (a.id.to_string(), 10_000)]
    );
    assert_eq!(ranks(&body), vec![1, 2]);
    assert_eq!(body["me"]["rank"], 3, "me keeps the global rank");
    let body = app.board_ok(Some(&c.token), "journey?view=friends").await;
    assert_eq!(ranking(&body), vec![(c.id.to_string(), 20_000)]);
    // A pending request is not a friendship; a block ends it.
    request(&app, &c, &a.name).await;
    let body = app.board_ok(Some(&a.token), "journey?view=friends").await;
    assert_eq!(ranking(&body).len(), 2);
    post(
        &app,
        &a,
        "/api/v1/blocks",
        Some(json!({"account_id": b.id.to_string()})),
    )
    .await;
    let body = app.board_ok(Some(&a.token), "journey?view=friends").await;
    assert_eq!(ranking(&body), vec![(a.id.to_string(), 10_000)]);
}

// ---------------------------------------------------------------------------------------------
// Crews
// ---------------------------------------------------------------------------------------------

async fn create_crew(app: &TestApp, p: &P, name: &str, tag: &str) -> Value {
    let r = post(
        app,
        p,
        "/api/v1/crews",
        Some(json!({ "name": name, "tag": tag })),
    )
    .await;
    assert_eq!(r.status, 201, "{:?}", r.json);
    r.json
}

async fn join(app: &TestApp, p: &P, code: &str) -> Resp {
    post(
        app,
        p,
        "/api/v1/crews/join",
        Some(json!({ "invite_code": code })),
    )
    .await
}

async fn act(app: &TestApp, p: &P, crew: &str, action: &str, target: &P) -> Resp {
    post(
        app,
        p,
        &format!("/api/v1/crews/{crew}/{action}"),
        Some(json!({ "account_id": target.id.to_string() })),
    )
    .await
}

fn roles(crew: &Value) -> Vec<(i64, String)> {
    crew["members"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| {
            (
                m["account_id"].as_str().unwrap().parse().unwrap(),
                m["role"].as_str().unwrap().to_string(),
            )
        })
        .collect()
}

#[tokio::test]
async fn crew_create_validation_and_filter() {
    let app = app().await;
    let (a, b) = (player(&app).await, player(&app).await);
    let create = |p: &P, name: &str, tag: &str| {
        let body = Some(json!({ "name": name, "tag": tag }));
        let token = p.token.clone();
        let app = &app;
        async move { app.call("POST", "/api/v1/crews", Some(&token), body).await }
    };
    // Rules and the profanity filter (names and tags, leetspeak included).
    assert_error(&create(&a, "Ab", "NR").await, 400, "invalid_crew_name");
    assert_error(
        &create(&a, "Night--Riders", "NR").await,
        400,
        "invalid_crew_name",
    );
    assert_error(
        &create(&a, "Sh1t Drivers", "NR").await,
        400,
        "crew_name_not_allowed",
    );
    assert_error(
        &create(&a, "Big Ass Crew", "NR").await,
        400,
        "crew_name_not_allowed",
    );
    assert_error(
        &create(&a, "Night Riders", "N").await,
        400,
        "invalid_crew_tag",
    );
    assert_error(
        &create(&a, "Night Riders", "NIGHT").await,
        400,
        "invalid_crew_tag",
    );
    assert_error(
        &create(&a, "Night Riders", "N-R").await,
        400,
        "invalid_crew_tag",
    );
    assert_error(
        &create(&a, "Night Riders", "A55").await,
        400,
        "crew_tag_not_allowed",
    );
    let r = app
        .call(
            "POST",
            "/api/v1/crews",
            Some(&a.token),
            Some(json!({"name": "X"})),
        )
        .await;
    assert_error(&r, 400, "invalid_body");
    // A good one: the creator owns it; the tag is stored upper case.
    let crew = create_crew(&app, &a, " Night Riders ", "nr").await;
    assert_eq!(crew["name"], "Night Riders");
    assert_eq!(crew["tag"], "NR");
    assert_eq!(crew["owner_id"], a.id.to_string());
    assert_eq!(crew["your_role"], "owner");
    assert_eq!(crew["member_count"], 1);
    assert_eq!(crew["max_members"], 16);
    assert_eq!(crew["created_at"], T0);
    assert_eq!(roles(&crew), vec![(a.id, "owner".to_string())]);
    let code = crew["invite_code"].as_str().unwrap();
    assert_eq!(code.len(), 8);
    // Uniqueness, case-insensitive; one crew per account.
    assert_error(
        &create(&b, "NIGHT RIDERS", "XY").await,
        409,
        "crew_name_taken",
    );
    assert_error(&create(&b, "Day Riders", "nr").await, 409, "crew_tag_taken");
    assert_error(
        &create(&a, "Day Riders", "DR").await,
        409,
        "already_in_crew",
    );
    // Another player sees it without the code; `mine` is 404 until they join.
    let id = crew["crew_id"].as_str().unwrap();
    let r = get(&app, &b, &format!("/api/v1/crews/{id}")).await;
    assert_eq!(r.status, 200);
    assert!(r.json["invite_code"].is_null());
    assert!(r.json["your_role"].is_null());
    assert_error(
        &get(&app, &b, "/api/v1/crews/mine").await,
        404,
        "not_in_crew",
    );
    assert_error(
        &get(&app, &b, "/api/v1/crews/999").await,
        404,
        "crew_not_found",
    );
    assert_error(
        &get(&app, &b, "/api/v1/crews/nope").await,
        404,
        "crew_not_found",
    );
    let r = get(&app, &a, "/api/v1/crews/mine").await;
    assert_eq!(r.status, 200);
    assert_eq!(r.json["invite_code"], code);
}

#[tokio::test]
async fn crew_roles_caps_and_codes() {
    let app = app_with(|c| c.social.crew_max_members = 4).await;
    let mut ps = Vec::new();
    for _ in 0..6 {
        ps.push(player(&app).await);
    }
    let (owner, off, m1, m2, late, other) = (&ps[0], &ps[1], &ps[2], &ps[3], &ps[4], &ps[5]);
    let crew = create_crew(&app, owner, "Coyotes", "CYT").await;
    let id = crew["crew_id"].as_str().unwrap().to_string();
    let code = crew["invite_code"].as_str().unwrap().to_string();
    // Join: the code is case-insensitive; unknown codes and second crews are refused.
    assert_error(
        &join(&app, off, "ZZZZZZZZ").await,
        404,
        "invalid_invite_code",
    );
    assert_error(&join(&app, off, "").await, 404, "invalid_invite_code");
    let r = join(&app, off, &code.to_lowercase()).await;
    assert_eq!(r.status, 200, "{:?}", r.json);
    assert_eq!(r.json["your_role"], "member");
    assert_error(&join(&app, off, &code).await, 409, "already_in_crew");
    app.clock.advance(10);
    assert_eq!(join(&app, m1, &code).await.status, 200);
    app.clock.advance(10);
    assert_eq!(join(&app, m2, &code).await.status, 200);
    // The cap (4 here; 16 by default).
    assert_error(&join(&app, late, &code).await, 409, "crew_full");
    // Promote / demote: the owner only.
    assert_error(
        &act(&app, off, &id, "promote", m1).await,
        403,
        "not_permitted",
    );
    let r = act(&app, owner, &id, "promote", off).await;
    assert_eq!(r.status, 200);
    assert_eq!(
        roles(&r.json),
        vec![
            (owner.id, "owner".into()),
            (off.id, "officer".into()),
            (m1.id, "member".into()),
            (m2.id, "member".into())
        ]
    );
    assert_error(
        &act(&app, owner, &id, "promote", owner).await,
        400,
        "cannot_change_own_role",
    );
    assert_error(
        &act(&app, owner, &id, "promote", other).await,
        404,
        "member_not_found",
    );
    assert_eq!(act(&app, owner, &id, "promote", m2).await.status, 200);
    assert_eq!(act(&app, owner, &id, "demote", m2).await.status, 200);
    // Kick: officers kick members only; members kick nobody; nobody kicks themselves.
    assert_error(&act(&app, m1, &id, "kick", m2).await, 403, "not_permitted");
    assert_error(
        &act(&app, off, &id, "kick", owner).await,
        403,
        "not_permitted",
    );
    assert_error(
        &act(&app, off, &id, "kick", off).await,
        400,
        "cannot_kick_self",
    );
    assert_error(&act(&app, other, &id, "kick", m1).await, 404, "not_in_crew");
    let r = act(&app, off, &id, "kick", m2).await;
    assert_eq!(r.status, 200, "{:?}", r.json);
    assert_eq!(r.json["member_count"], 3);
    assert_error(
        &act(&app, off, &id, "kick", m2).await,
        404,
        "member_not_found",
    );
    // Now there is room.
    assert_eq!(join(&app, late, &code).await.status, 200);
    // Rotate the code: owner or officer; the old code stops working.
    let r = post(&app, m1, &format!("/api/v1/crews/{id}/invite-code"), None).await;
    assert_error(&r, 403, "not_permitted");
    let r = post(&app, off, &format!("/api/v1/crews/{id}/invite-code"), None).await;
    assert_eq!(r.status, 200);
    let new_code = r.json["invite_code"].as_str().unwrap().to_string();
    assert_ne!(new_code, code);
    assert_eq!(act(&app, owner, &id, "kick", late).await.status, 200);
    assert_error(&join(&app, late, &code).await, 404, "invalid_invite_code");
    assert_eq!(join(&app, late, &new_code).await.status, 200);
    // Transfer: the owner only, to a member; the old owner becomes an officer.
    assert_error(
        &act(&app, off, &id, "transfer", m1).await,
        403,
        "not_permitted",
    );
    assert_error(
        &act(&app, owner, &id, "transfer", owner).await,
        400,
        "cannot_transfer_to_self",
    );
    let r = act(&app, owner, &id, "transfer", m1).await;
    assert_eq!(r.status, 200);
    assert_eq!(r.json["owner_id"], m1.id.to_string());
    assert_eq!(r.json["your_role"], "officer");
    // Disband: the owner only.
    let r = delete(&app, owner, &format!("/api/v1/crews/{id}")).await;
    assert_error(&r, 403, "not_permitted");
    // Leaving as owner hands the crew to the longest-standing officer.
    let r = post(&app, m1, &format!("/api/v1/crews/{id}/leave"), None).await;
    assert_eq!(r.status, 200);
    assert_eq!(r.json["new_owner_id"], owner.id.to_string());
    assert_eq!(r.json["disbanded"], false);
    assert_error(
        &post(&app, m1, &format!("/api/v1/crews/{id}/leave"), None).await,
        404,
        "not_in_crew",
    );
    assert_eq!(
        delete(&app, owner, &format!("/api/v1/crews/{id}"))
            .await
            .status,
        204
    );
    assert_error(
        &get(&app, owner, &format!("/api/v1/crews/{id}")).await,
        404,
        "crew_not_found",
    );
    assert_error(
        &get(&app, off, "/api/v1/crews/mine").await,
        404,
        "not_in_crew",
    );
    // The released members may found or join another crew.
    create_crew(&app, off, "Coyotes", "CYT").await;
}

#[tokio::test]
async fn owner_succession_prefers_officers_then_seniority() {
    let app = app().await;
    let (a, b, c) = (player(&app).await, player(&app).await, player(&app).await);
    let crew = create_crew(&app, &a, "Lone Wolves", "LW").await;
    let id = crew["crew_id"].as_str().unwrap().to_string();
    let code = crew["invite_code"].as_str().unwrap().to_string();
    join(&app, &b, &code).await;
    app.clock.advance(5);
    join(&app, &c, &code).await;
    act(&app, &a, &id, "promote", &c).await;
    // The officer wins over the longer-standing member.
    let r = post(&app, &a, &format!("/api/v1/crews/{id}/leave"), None).await;
    assert_eq!(r.json["new_owner_id"], c.id.to_string());
    // Without officers, the longest-standing member; alone, the crew is disbanded.
    let r = post(&app, &c, &format!("/api/v1/crews/{id}/leave"), None).await;
    assert_eq!(r.json["new_owner_id"], b.id.to_string());
    let r = post(&app, &b, &format!("/api/v1/crews/{id}/leave"), None).await;
    assert_eq!(r.json["disbanded"], true);
    assert!(r.json["new_owner_id"].is_null());
    assert_eq!(
        count(
            &app,
            "SELECT COUNT(*) FROM crews WHERE id = ?",
            id.parse().unwrap()
        )
        .await,
        0
    );
}

// ---------------------------------------------------------------------------------------------
// Crew tags and Loop crew sums on the boards
// ---------------------------------------------------------------------------------------------

fn mp_run(account_id: i64, score: u32) -> MultiplayerRun {
    MultiplayerRun {
        account_id,
        map_id: "loop_v1".into(),
        room: RoomKind::Public,
        score,
        duration_s: 600.0,
        distance_m: 25_000.0,
        stats: json!({"passes": 10}),
        car: "coupe".into(),
        client_build: 1,
        ended_at: T0,
        crew: None,
    }
}

fn crew_score(board: &Value) -> Option<i64> {
    board["entries"][0]["score"].as_i64()
}

#[tokio::test]
async fn crew_tags_and_loop_crew_sums() {
    let app = runs_app().await;
    let mut ps = Vec::new();
    for _ in 0..6 {
        ps.push(player(&app).await);
    }
    for (p, score) in ps.iter().zip([600u32, 500, 400, 300, 200, 100]) {
        app.state
            .boards
            .record_multiplayer_run(&mp_run(p.id, score))
            .await
            .unwrap();
    }
    // Creating the crew counts the owner's season best at once.
    let crew = create_crew(&app, &ps[5], "Mirage", "MRG").await;
    let id = crew["crew_id"].as_str().unwrap().to_string();
    let code = crew["invite_code"].as_str().unwrap().to_string();
    let board = app.board_ok(None, "loop_crew").await;
    assert_eq!(crew_score(&board), Some(100));
    assert_eq!(board["entries"][0]["crew_id"], id);
    assert_eq!(board["entries"][0]["crew_name"], "Mirage");
    assert_eq!(board["entries"][0]["crew_tag"], "MRG");
    assert!(board["entries"][0]["account_id"].is_null());
    // Joins: the best 4 members' season bests.
    for p in &ps[..5] {
        assert_eq!(join(&app, p, &code).await.status, 200);
    }
    let board = app.board_ok(None, "loop_crew").await;
    assert_eq!(crew_score(&board), Some(600 + 500 + 400 + 300));
    // The tag on the members' entries (Loop and every other board); not on others'.
    let outsider = player(&app).await;
    app.state
        .boards
        .record_multiplayer_run(&mp_run(outsider.id, 50))
        .await
        .unwrap();
    let body = app.board_ok(Some(&ps[0].token), "loop").await;
    let tags: Vec<Value> = body["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["crew_tag"].clone())
        .collect();
    assert_eq!(tags[..6], vec![json!("MRG"); 6][..]);
    assert!(tags[6].is_null());
    assert_eq!(body["me"]["crew_tag"], "MRG");
    // "me" on the crew board is the caller's crew.
    let body = app
        .board_ok(Some(&ps[2].token), "loop_crew?view=around_me")
        .await;
    assert_eq!(body["me"]["crew_id"], id);
    assert_eq!(body["me"]["rank"], 1);
    // Kick and leave recompute the sum.
    assert_eq!(act(&app, &ps[5], &id, "kick", &ps[0]).await.status, 200);
    assert_eq!(
        crew_score(&app.board_ok(None, "loop_crew").await),
        Some(500 + 400 + 300 + 200)
    );
    assert!(app.board_ok(None, "loop").await["entries"][0]["crew_tag"].is_null());
    post(&app, &ps[1], &format!("/api/v1/crews/{id}/leave"), None).await;
    assert_eq!(
        crew_score(&app.board_ok(None, "loop_crew").await),
        Some(400 + 300 + 200 + 100)
    );
    // Account deletion recomputes it too.
    let r = app
        .call("DELETE", "/api/v1/account", Some(&ps[2].token), None)
        .await;
    assert_eq!(r.status, 204);
    assert_eq!(
        crew_score(&app.board_ok(None, "loop_crew").await),
        Some(300 + 200 + 100)
    );
    // An admin rename shows at once; disbanding removes the crew's entries.
    admin::crew_rename(
        app.db(),
        id.parse().unwrap(),
        Some("Dust Devils"),
        Some("DD"),
    )
    .await
    .unwrap();
    let board = app.board_ok(None, "loop_crew").await;
    assert_eq!(board["entries"][0]["crew_name"], "Dust Devils");
    assert_eq!(board["entries"][0]["crew_tag"], "DD");
    assert_eq!(
        delete(&app, &ps[5], &format!("/api/v1/crews/{id}"))
            .await
            .status,
        204
    );
    assert_eq!(app.board_ok(None, "loop_crew").await["total"], 0);
    // N6's snapshot of a crew.
    let crew = create_crew(&app, &ps[3], "Nomads", "NMD").await;
    join(&app, &ps[4], crew["invite_code"].as_str().unwrap()).await;
    let mut conn = app.db().acquire().await.unwrap();
    let snap = social::crew_snapshot(&mut conn, ps[4].id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(snap.crew_id.to_string(), crew["crew_id"].as_str().unwrap());
    assert_eq!(snap.member_ids, vec![ps[3].id, ps[4].id]);
    assert!(social::crew_snapshot(&mut conn, outsider.id)
        .await
        .unwrap()
        .is_none());
}

// ---------------------------------------------------------------------------------------------
// Account deletion
// ---------------------------------------------------------------------------------------------

#[tokio::test]
async fn account_deletion_cascade() {
    let app = app().await;
    let mut ps = Vec::new();
    for _ in 0..7 {
        ps.push(player(&app).await);
    }
    let (gone, member, officer, friend, blocked, blocker, pending) =
        (&ps[0], &ps[1], &ps[2], &ps[3], &ps[4], &ps[5], &ps[6]);
    befriend(&app, gone, friend).await;
    request(&app, pending, &gone.name).await;
    post(
        &app,
        gone,
        "/api/v1/blocks",
        Some(json!({"account_id": blocked.id.to_string()})),
    )
    .await;
    post(
        &app,
        blocker,
        "/api/v1/blocks",
        Some(json!({"account_id": gone.id.to_string()})),
    )
    .await;
    let crew = create_crew(&app, gone, "Outlaws", "OUT").await;
    let id = crew["crew_id"].as_str().unwrap().to_string();
    let code = crew["invite_code"].as_str().unwrap().to_string();
    join(&app, member, &code).await;
    app.clock.advance(5);
    join(&app, officer, &code).await;
    act(&app, gone, &id, "promote", officer).await;
    assert_eq!(report(&app, friend, gone, "cheating").await.status, 201);
    assert_eq!(report(&app, gone, blocked, "cheating").await.status, 201);

    let r = app
        .call("DELETE", "/api/v1/account", Some(&gone.token), None)
        .await;
    assert_eq!(r.status, 204);
    let g = gone.id;
    assert_eq!(
        count(
            &app,
            "SELECT COUNT(*) FROM friends WHERE account_a = ?1 OR account_b = ?1",
            g
        )
        .await,
        0
    );
    assert_eq!(
        count(
            &app,
            "SELECT COUNT(*) FROM blocks WHERE account_id = ?1 OR blocked_id = ?1",
            g
        )
        .await,
        0
    );
    assert_eq!(
        count(
            &app,
            "SELECT COUNT(*) FROM crew_members WHERE account_id = ?",
            g
        )
        .await,
        0
    );
    assert!(ids(&friends(&app, friend).await, "friends").is_empty());
    assert!(ids(&friends(&app, pending).await, "outgoing").is_empty());
    // The crew passed to the officer (over the longer-standing member).
    let r = get(&app, officer, "/api/v1/crews/mine").await;
    assert_eq!(r.json["owner_id"], officer.id.to_string());
    assert_eq!(
        roles(&r.json),
        vec![(officer.id, "owner".into()), (member.id, "member".into())]
    );
    // Reports stay, with the deleted side nulled.
    let rows: Vec<(Option<i64>, Option<i64>)> =
        sqlx::query_as("SELECT reporter_id, target_id FROM reports ORDER BY id")
            .fetch_all(app.db())
            .await
            .unwrap();
    assert_eq!(
        rows,
        vec![(Some(friend.id), None), (None, Some(blocked.id))]
    );
    let detail: String =
        sqlx::query_scalar("SELECT detail FROM admin_log WHERE action = 'account_delete'")
            .fetch_one(app.db())
            .await
            .unwrap();
    assert!(
        detail.contains(
            "friends=2 blocks=2 crew_memberships=1 crew_transferred=true \
             crew_disbanded=false reports_kept=2"
        ),
        "{detail}"
    );
    // A crew of one is disbanded with its owner.
    let solo = player(&app).await;
    let crew = create_crew(&app, &solo, "Solo", "SOLO").await;
    app.call("DELETE", "/api/v1/account", Some(&solo.token), None)
        .await;
    let solo_id: i64 = crew["crew_id"].as_str().unwrap().parse().unwrap();
    assert_eq!(
        count(&app, "SELECT COUNT(*) FROM crews WHERE id = ?", solo_id).await,
        0
    );
}

// ---------------------------------------------------------------------------------------------
// Reports
// ---------------------------------------------------------------------------------------------

#[tokio::test]
async fn reports_validation_and_daily_limit() {
    let app = app_with(|c| {
        long_tokens(c);
        c.social.reports_per_day = 3;
    })
    .await;
    let (a, b) = (player(&app).await, player(&app).await);
    let report = |body: Value| post(&app, &a, "/api/v1/reports", Some(body));
    let target = b.id.to_string();
    let r = report(json!({
        "target_account_id": target, "reason": "offensive_name",
        "context": {"source": "leaderboard", "board": "loop", "run_id": "7"}
    }))
    .await;
    assert_eq!(r.status, 201, "{:?}", r.json);
    let id: i64 = r.json["report_id"].as_str().unwrap().parse().unwrap();
    let row: (i64, i64, String, String, i64, i64) = sqlx::query_as(
        "SELECT reporter_id, target_id, reason, context, created_at, handled FROM reports WHERE id = ?",
    )
    .bind(id)
    .fetch_one(app.db())
    .await
    .unwrap();
    assert_eq!(
        row,
        (
            a.id,
            b.id,
            "offensive_name".into(),
            r#"{"board":"loop","run_id":"7","source":"leaderboard"}"#.into(),
            T0,
            0
        )
    );
    // Errors (none of them count toward the limit).
    assert_error(
        &report(json!({"target_account_id": target, "reason": "rude"})).await,
        400,
        "invalid_reason",
    );
    assert_error(
        &report(json!({"target_account_id": target, "reason": "other", "context": [1]})).await,
        400,
        "invalid_context",
    );
    let big = "x".repeat(1_100);
    assert_error(
        &report(json!({"target_account_id": target, "reason": "other", "context": {"t": big}}))
            .await,
        400,
        "invalid_context",
    );
    assert_error(
        &report(json!({"target_account_id": a.id.to_string(), "reason": "other"})).await,
        400,
        "cannot_report_self",
    );
    assert_error(
        &report(json!({"target_account_id": "99999", "reason": "other"})).await,
        404,
        "player_not_found",
    );
    assert_error(
        &report(json!({"target_account_id": target, "reason": "other", "extra": 1})).await,
        400,
        "invalid_body",
    );
    // The limit: 3 per rolling day, then 429 until the oldest leaves the window.
    app.clock.advance(100);
    let ok = json!({"target_account_id": target, "reason": "griefing"});
    assert_eq!(report(ok.clone()).await.status, 201);
    assert_eq!(report(ok.clone()).await.status, 201);
    let r = report(ok.clone()).await;
    assert_error(&r, 429, "rate_limited");
    assert_eq!(r.json["retry_after_secs"], DAY - 100);
    assert_eq!(r.headers["retry-after"], (DAY - 100).to_string());
    // Per account: B can still report.
    let r = post(
        &app,
        &b,
        "/api/v1/reports",
        Some(json!({"target_account_id": a.id.to_string(), "reason": "other"})),
    )
    .await;
    assert_eq!(r.status, 201);
    app.clock.advance(DAY - 100);
    assert_eq!(report(ok.clone()).await.status, 201);
    assert_error(&report(ok).await, 429, "rate_limited");
}

// ---------------------------------------------------------------------------------------------
// The social rate limit
// ---------------------------------------------------------------------------------------------

#[tokio::test]
async fn social_writes_are_rate_limited_per_account() {
    let app = app_with(|c| {
        c.rate_limits.social_per_hour = 1;
        c.rate_limits.social_burst = 2;
    })
    .await;
    let (a, b, c, d) = (
        player(&app).await,
        player(&app).await,
        player(&app).await,
        player(&app).await,
    );
    assert_eq!(request(&app, &a, &b.name).await.status, 201);
    let r = post(
        &app,
        &a,
        "/api/v1/blocks",
        Some(json!({"account_id": c.id.to_string()})),
    )
    .await;
    assert_eq!(r.status, 201);
    let r = request(&app, &a, &d.name).await;
    assert_error(&r, 429, "rate_limited");
    assert!(r.headers.contains_key("retry-after"));
    for (path, body) in [
        (
            "/api/v1/crews",
            json!({"name": "Rate Limited", "tag": "RL"}),
        ),
        ("/api/v1/crews/join", json!({"invite_code": "ABCDEFGH"})),
        (
            "/api/v1/reports",
            json!({"target_account_id": b.id.to_string(), "reason": "other"}),
        ),
        ("/api/v1/blocks", json!({"account_id": d.id.to_string()})),
    ] {
        assert_error(&post(&app, &a, path, Some(body)).await, 429, "rate_limited");
    }
    // Reads and other accounts are not affected.
    assert_eq!(get(&app, &a, "/api/v1/friends").await.status, 200);
    assert_eq!(get(&app, &a, "/api/v1/blocks").await.status, 200);
    assert_eq!(request(&app, &b, &d.name).await.status, 201);
}

// ---------------------------------------------------------------------------------------------
// Admin commands
// ---------------------------------------------------------------------------------------------

#[tokio::test]
async fn admin_reports_and_crews() {
    let app = app().await;
    let (a, b) = (player(&app).await, player(&app).await);
    assert_eq!(
        admin::reports(app.db(), false, 50).await.unwrap(),
        "no reports"
    );
    let first = report(&app, &a, &b, "cheating").await.json["report_id"]
        .as_str()
        .unwrap()
        .parse::<i64>()
        .unwrap();
    report(&app, &b, &a, "harassment").await;
    let out = admin::reports(app.db(), false, 50).await.unwrap();
    let lines: Vec<&str> = out.lines().collect();
    assert_eq!(lines.len(), 2, "{out}");
    assert!(lines[1].starts_with(&format!("#{first} ")), "{out}");
    assert!(
        lines[1].contains(&format!(
            "reporter={} target={} reason=cheating unhandled",
            a.id, b.id
        )),
        "{out}"
    );
    assert!(lines[1].ends_with(r#"context={"source":"room"}"#), "{out}");
    assert_eq!(
        admin::reports(app.db(), false, 1)
            .await
            .unwrap()
            .lines()
            .count(),
        1
    );
    let msg = admin::report_handle(app.db(), first, T0 + 5).await.unwrap();
    assert!(msg.contains("marked handled"), "{msg}");
    assert!(admin::report_handle(app.db(), first, T0 + 6)
        .await
        .unwrap()
        .contains("already"));
    assert!(admin::report_handle(app.db(), 999, T0).await.is_err());
    let out = admin::reports(app.db(), true, 50).await.unwrap();
    assert_eq!(out.lines().count(), 1, "{out}");
    assert!(out.contains("reason=harassment"), "{out}");
    let all = admin::reports(app.db(), false, 50).await.unwrap();
    assert!(
        all.contains(&format!("#{first} ")) && all.contains("handled=1790000005"),
        "{all}"
    );
    // Deleted sides show as `deleted`.
    app.call("DELETE", "/api/v1/account", Some(&b.token), None)
        .await;
    let all = admin::reports(app.db(), false, 50).await.unwrap();
    assert!(
        all.contains(&format!("reporter=deleted target={}", a.id)),
        "{all}"
    );
    assert!(
        all.contains(&format!("reporter={} target=deleted", a.id)),
        "{all}"
    );

    // Crews: rename (rules, filter, uniqueness) and disband.
    let crew = create_crew(&app, &a, "Rattlers", "RTL").await;
    let other = player(&app).await;
    create_crew(&app, &other, "Vipers", "VPR").await;
    let id: i64 = crew["crew_id"].as_str().unwrap().parse().unwrap();
    let msg = admin::crew_rename(app.db(), id, Some("Sidewinders"), None)
        .await
        .unwrap();
    assert_eq!(msg, format!("crew {id} renamed to Sidewinders [RTL]"));
    assert!(admin::crew_rename(app.db(), id, Some("vipers"), None)
        .await
        .is_err());
    assert!(admin::crew_rename(app.db(), id, None, Some("vpr"))
        .await
        .is_err());
    assert!(admin::crew_rename(app.db(), id, Some("Sh1t Crew"), None)
        .await
        .is_err());
    assert!(admin::crew_rename(app.db(), id, None, None).await.is_err());
    assert!(admin::crew_rename(app.db(), 999, Some("Nope"), None)
        .await
        .is_err());
    let msg = admin::crew_rename(app.db(), id, None, Some("sw"))
        .await
        .unwrap();
    assert_eq!(msg, format!("crew {id} renamed to Sidewinders [SW]"));
    let msg = admin::crew_disband(app.db(), id).await.unwrap();
    assert!(msg.contains("1 members released"), "{msg}");
    assert!(admin::crew_disband(app.db(), id).await.is_err());
    assert_error(
        &get(&app, &a, "/api/v1/crews/mine").await,
        404,
        "not_in_crew",
    );
    let log: Vec<String> =
        sqlx::query_scalar("SELECT action FROM admin_log WHERE actor = 'cli' ORDER BY id")
            .fetch_all(app.db())
            .await
            .unwrap();
    assert_eq!(
        log,
        vec![
            "report_handle",
            "crew_rename",
            "crew_rename",
            "crew_disband"
        ]
    );
}
