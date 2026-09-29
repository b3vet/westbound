//! `/ws/echo` (the ops echo): echo, limits, keepalive, caps, shutdown. The protocol
//! gateway on `/ws` is tested in `gateway.rs`.
mod common;

use std::time::Duration;

use common::{eventually, next_msg};
use futures_util::{SinkExt, StreamExt};
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::Message;
use westbound_server::metrics::Metrics;

fn close_code(m: Option<Message>) -> Option<CloseCode> {
    match m {
        Some(Message::Close(Some(f))) => Some(f.code),
        _ => None,
    }
}

#[tokio::test]
async fn echoes_binary_and_text() {
    let s = common::start().await;
    let mut ws = s.connect_echo().await;
    let payload: Vec<u8> = (0..=255u8).collect();
    ws.send(Message::Binary(payload.clone().into()))
        .await
        .unwrap();
    assert_eq!(
        next_msg(&mut ws).await,
        Some(Message::Binary(payload.into()))
    );
    ws.send(Message::Text("hello westbound".into()))
        .await
        .unwrap();
    assert_eq!(
        next_msg(&mut ws).await,
        Some(Message::Text("hello westbound".into()))
    );
    let m = s.metrics().clone();
    eventually("frame counters", || {
        Metrics::get(&m.ws_frames_in) == 2 && Metrics::get(&m.ws_frames_out) == 2
    })
    .await;
    assert_eq!(Metrics::get(&m.ws_connections), 1);
    ws.close(None).await.unwrap();
    eventually("connection released", || {
        Metrics::get(&m.ws_connections) == 0
    })
    .await;
    s.stop().await;
}

#[tokio::test]
async fn max_size_message_passes_oversize_is_closed_1009() {
    let s = common::start().await;
    let max = s.state.config.limits.max_message_bytes;
    assert_eq!(max, 16 * 1024, "spec: 16 KB inbound max");
    let mut ws = s.connect_echo().await;
    ws.send(Message::Binary(vec![7u8; max].into()))
        .await
        .unwrap();
    assert_eq!(
        next_msg(&mut ws).await,
        Some(Message::Binary(vec![7u8; max].into()))
    );
    ws.send(Message::Binary(vec![7u8; max + 1].into()))
        .await
        .unwrap();
    assert_eq!(close_code(next_msg(&mut ws).await), Some(CloseCode::Size));
    let m = s.metrics().clone();
    eventually("oversize counted", || {
        Metrics::get(&m.ws_oversize_closed) == 1
    })
    .await;
    eventually("connection released", || {
        Metrics::get(&m.ws_connections) == 0
    })
    .await;
    s.stop().await;
}

#[tokio::test]
async fn slow_client_is_disconnected_when_queue_fills() {
    let s = common::start().await;
    assert_eq!(
        s.state.config.limits.outbound_queue_frames, 64,
        "spec: 64 frames"
    );
    let ws = s.connect_echo().await;
    let (mut tx, rx) = ws.split();
    // Never read: the echoes fill the socket buffers, then the 64-frame queue.
    let m = s.metrics().clone();
    let chunk = vec![1u8; 16_000];
    let mut sent = 0;
    while Metrics::get(&m.ws_slow_client_closed) == 0 && sent < 20_000 {
        if tx
            .send(Message::Binary(chunk.clone().into()))
            .await
            .is_err()
        {
            break;
        }
        sent += 1;
    }
    eventually("slow client closed", || {
        Metrics::get(&m.ws_slow_client_closed) == 1
    })
    .await;
    eventually("connection released", || {
        Metrics::get(&m.ws_connections) == 0
    })
    .await;
    drop(rx);
    s.stop().await;
}

#[tokio::test]
async fn silent_client_times_out_responsive_client_stays() {
    let s = common::start_with(|c| {
        c.limits.ping_interval_ms = 100;
        c.limits.dead_after_ms = 500;
    })
    .await;
    let m = s.metrics().clone();

    // Responsive: its reader answers pings with pongs.
    let alive = s.connect_echo().await;
    let (_alive_tx, mut alive_rx) = alive.split();
    let reader = tokio::spawn(async move {
        let mut pings = 0u32;
        while let Some(Ok(msg)) = alive_rx.next().await {
            if matches!(msg, Message::Ping(_)) {
                pings += 1;
            }
            if matches!(msg, Message::Close(_)) {
                break;
            }
        }
        pings
    });

    // Silent: never polled, so it never answers a ping.
    let _silent = s.connect_echo().await;
    eventually("silent client timed out", || {
        Metrics::get(&m.ws_timeout_closed) == 1
    })
    .await;
    tokio::time::sleep(Duration::from_millis(1_200)).await;
    assert_eq!(
        Metrics::get(&m.ws_timeout_closed),
        1,
        "responsive client kept"
    );
    assert_eq!(Metrics::get(&m.ws_connections), 1);

    s.state.shutdown.cancel();
    let pings = tokio::time::timeout(common::WAIT, reader)
        .await
        .unwrap()
        .unwrap();
    assert!(pings >= 5, "server pinged every interval, got {pings}");
    s.stop().await;
}

#[tokio::test]
async fn connection_cap_refuses_extra_clients() {
    let s = common::start_with(|c| c.limits.max_connections = 2).await;
    let _a = s.connect_echo().await;
    let _b = s.connect_echo().await;
    let url = format!("ws://{}/ws/echo", s.addr);
    let err = tokio_tungstenite::connect_async(url).await.unwrap_err();
    match err {
        tokio_tungstenite::tungstenite::Error::Http(resp) => assert_eq!(resp.status(), 503),
        e => panic!("expected HTTP 503, got {e}"),
    }
    assert_eq!(Metrics::get(&s.metrics().ws_rejected_full), 1);
    s.stop().await;
}

#[tokio::test]
async fn shutdown_sends_close_frame_and_stops() {
    let s = common::start().await;
    let mut a = s.connect_echo().await;
    let mut b = s.connect_echo().await;
    s.state.shutdown.cancel();
    assert_eq!(close_code(next_msg(&mut a).await), Some(CloseCode::Away));
    assert_eq!(close_code(next_msg(&mut b).await), Some(CloseCode::Away));
    let m = s.metrics().clone();
    s.stop().await;
    assert_eq!(Metrics::get(&m.ws_connections), 0);
}

#[tokio::test]
async fn echo_route_can_be_disabled() {
    let s = common::start_with(|c| c.gateway.echo_enabled = false).await;
    let url = format!("ws://{}/ws/echo", s.addr);
    match tokio_tungstenite::connect_async(url).await.unwrap_err() {
        tokio_tungstenite::tungstenite::Error::Http(resp) => assert_eq!(resp.status(), 404),
        e => panic!("expected HTTP 404, got {e}"),
    }
    s.stop().await;
}
