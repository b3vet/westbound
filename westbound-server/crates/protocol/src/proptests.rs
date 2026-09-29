//! Property tests (multiplayer handoff → Testing → Fuzzing: malformed and oversized inbound
//! messages never crash a room). Every message type round-trips through bytes and JSON;
//! random and mutated bytes never panic the decoder; anything that decodes re-encodes to the
//! exact same bytes (the encoding is canonical).

use proptest::collection::vec;
use proptest::prelude::*;

use crate::frame::{decode_frame, encode_frame, FrameBuilder, Message};
use crate::messages::*;
use crate::{DecodeError, MAX_FRAME_LEN};

fn round_trip<M>(msg: &M)
where
    M: Message + PartialEq + std::fmt::Debug + serde::Serialize + serde::de::DeserializeOwned,
{
    msg.validate().expect("strategies produce valid messages");
    let bytes = encode_frame(std::slice::from_ref(msg)).expect("encodes");
    assert_eq!(bytes.len(), msg.encoded_len());
    let back: Vec<M> = decode_frame(&bytes).expect("decodes");
    assert_eq!(back.len(), 1);
    assert_eq!(back.first(), Some(msg));
    let json = serde_json::to_value(msg).expect("json");
    let from_json: M = serde_json::from_value(json).expect("from json");
    assert_eq!(&from_json, msg);
}

/// Anything that decodes must re-encode to exactly the input bytes.
fn canonical<M>(bytes: &[u8])
where
    M: Message + std::fmt::Debug,
{
    if let Ok(msgs) = decode_frame::<M>(bytes) {
        let again = encode_frame(&msgs).expect("decoded messages re-encode");
        assert_eq!(&again[..], bytes);
    }
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 512, .. ProptestConfig::default() })]

    #[test]
    fn client_messages_round_trip(msg in any::<ClientMsg>()) {
        round_trip(&msg);
    }

    #[test]
    fn server_messages_round_trip(msg in any::<ServerMsg>()) {
        round_trip(&msg);
    }

    #[test]
    fn multi_message_frames_round_trip(msgs in vec(any::<ServerMsg>(), 1..6)) {
        let mut fb = FrameBuilder::new();
        let mut pushed = Vec::new();
        for m in &msgs {
            if fb.push(m).is_ok() {
                pushed.push(m.clone());
            }
        }
        let bytes = fb.finish();
        prop_assume!(!pushed.is_empty());
        let back: Vec<ServerMsg> = decode_frame(&bytes).unwrap();
        prop_assert_eq!(back, pushed);
    }

    #[test]
    fn random_bytes_never_panic(bytes in vec(any::<u8>(), 0..2048)) {
        let _ = decode_frame::<ClientMsg>(&bytes);
        let _ = decode_frame::<ServerMsg>(&bytes);
        canonical::<ClientMsg>(&bytes);
        canonical::<ServerMsg>(&bytes);
    }

    #[test]
    fn framed_random_payloads_never_panic(ty in any::<u8>(), payload in vec(any::<u8>(), 0..512)) {
        // Valid header, arbitrary payload: exercises every message parser on junk.
        let mut bytes = vec![ty];
        bytes.extend_from_slice(&(payload.len() as u16).to_le_bytes());
        bytes.extend_from_slice(&payload);
        let _ = decode_frame::<ClientMsg>(&bytes);
        let _ = decode_frame::<ServerMsg>(&bytes);
        canonical::<ClientMsg>(&bytes);
        canonical::<ServerMsg>(&bytes);
    }

    #[test]
    fn mutated_client_frames_never_panic(
        msg in any::<ClientMsg>(),
        flips in vec((any::<prop::sample::Index>(), any::<u8>()), 1..4),
        cut in any::<prop::sample::Index>(),
        truncate in any::<bool>(),
    ) {
        let mut bytes = encode_frame(&[msg]).unwrap().to_vec();
        for (at, v) in flips {
            let i = at.index(bytes.len());
            bytes[i] ^= v;
        }
        if truncate {
            bytes.truncate(cut.index(bytes.len() + 1));
        }
        let _ = decode_frame::<ClientMsg>(&bytes);
        canonical::<ClientMsg>(&bytes);
    }

    #[test]
    fn mutated_server_frames_never_panic(
        msg in any::<ServerMsg>(),
        flips in vec((any::<prop::sample::Index>(), any::<u8>()), 1..4),
        cut in any::<prop::sample::Index>(),
        truncate in any::<bool>(),
    ) {
        let mut bytes = encode_frame(&[msg]).unwrap().to_vec();
        for (at, v) in flips {
            let i = at.index(bytes.len());
            bytes[i] ^= v;
        }
        if truncate {
            bytes.truncate(cut.index(bytes.len() + 1));
        }
        let _ = decode_frame::<ServerMsg>(&bytes);
        canonical::<ServerMsg>(&bytes);
    }

    #[test]
    fn batch_writer_matches_vec_encoding(
        tick in any::<u32>(),
        cars in vec(any::<CorrectionEntry>(), 1..=usize::from(MAX_TRAFFIC_BATCH)),
        players in vec(any::<PlayerStateEntry>(), 1..=usize::from(MAX_ROOM_PLAYERS)),
        spawns in vec(any::<TrafficSpawnEntry>(), 1..=usize::from(MAX_TRAFFIC_BATCH)),
        despawns in vec(any::<u16>(), 1..=usize::from(MAX_TRAFFIC_BATCH)),
        intents in vec(any::<TrafficIntentEntry>(), 1..=usize::from(MAX_INTENT_BATCH)),
    ) {
        let mut fb = FrameBuilder::new();
        {
            let mut b = fb.traffic_corrections(tick).unwrap();
            for c in &cars { b.push(c).unwrap(); }
        }
        {
            let mut b = fb.player_states().unwrap();
            for p in &players { b.push(p).unwrap(); }
        }
        {
            let mut b = fb.traffic_spawns().unwrap();
            for s in &spawns { b.push(s).unwrap(); }
        }
        {
            let mut b = fb.traffic_despawns().unwrap();
            for d in &despawns { b.push(d).unwrap(); }
        }
        {
            let mut b = fb.traffic_intents().unwrap();
            for i in &intents { b.push(i).unwrap(); }
        }
        // Empty batches leave no trace.
        drop(fb.traffic_spawns().unwrap());
        let streamed = fb.finish();
        let expected = encode_frame(&[
            ServerMsg::TrafficCorrection(TrafficCorrection { tick, cars }),
            ServerMsg::PlayerStates(PlayerStates { players }),
            ServerMsg::TrafficSpawn(TrafficSpawn { cars: spawns }),
            ServerMsg::TrafficDespawn(TrafficDespawn { car_ids: despawns }),
            ServerMsg::TrafficIntent(TrafficIntent { intents }),
        ]).unwrap();
        prop_assert_eq!(&streamed[..], &expected[..]);
    }
}

#[test]
fn oversize_frame_is_rejected_before_parsing() {
    let bytes = vec![0u8; MAX_FRAME_LEN + 1];
    assert_eq!(
        decode_frame::<ClientMsg>(&bytes).unwrap_err(),
        DecodeError::FrameTooLarge {
            len: MAX_FRAME_LEN + 1,
            max: MAX_FRAME_LEN
        }
    );
}

#[test]
fn builder_respects_frame_limit_and_batch_caps() {
    let mut fb = FrameBuilder::with_limit(64);
    let sync = ServerMsg::ScoreSync(ScoreSync::default());
    let mut pushed = 0;
    while fb.push(&sync).is_ok() {
        pushed += 1;
    }
    assert_eq!(pushed, 64 / sync.encoded_len());
    let before = fb.len();
    assert!(matches!(
        fb.push(&sync),
        Err(crate::EncodeError::FrameFull { .. })
    ));
    assert_eq!(fb.len(), before, "a failed push writes nothing");

    let mut fb = FrameBuilder::new();
    {
        let mut b = fb.traffic_intents().unwrap();
        for _ in 0..MAX_INTENT_BATCH {
            b.push(&TrafficIntentEntry::default()).unwrap();
        }
        assert!(b.is_full());
        assert!(matches!(
            b.push(&TrafficIntentEntry::default()),
            Err(crate::EncodeError::BatchFull { .. })
        ));
    }
    let frame = fb.finish();
    let msgs: Vec<ServerMsg> = decode_frame(&frame).unwrap();
    assert!(
        matches!(&msgs[..], [ServerMsg::TrafficIntent(t)] if t.intents.len() == usize::from(MAX_INTENT_BATCH))
    );
}

#[test]
fn builder_reuses_its_allocation() {
    let mut fb = FrameBuilder::new();
    for tick in 0..1000u32 {
        fb.push(&ServerMsg::Pong(Pong {
            client_time_ms: tick,
            server_tick: tick,
            tick_fraction: 0,
        }))
        .unwrap();
        let frame = fb.finish();
        assert_eq!(frame.len(), 3 + 10);
        drop(frame);
    }
    assert!(fb.is_empty());
}

#[test]
fn invalid_entries_are_refused_by_batches() {
    let mut fb = FrameBuilder::new();
    let mut b = fb.traffic_corrections(1).unwrap();
    let bad = CorrectionEntry {
        d_cm: MAX_ABS_D_CM + 1,
        ..CorrectionEntry::default()
    };
    assert!(matches!(b.push(&bad), Err(crate::EncodeError::Invalid(_))));
    drop(b);
    assert!(fb.is_empty());
}
