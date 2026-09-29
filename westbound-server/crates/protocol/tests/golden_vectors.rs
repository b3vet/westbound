//! Golden-vector check (multiplayer handoff → Networking protocol → Golden vectors; Testing →
//! Codec: every golden vector round-trips). The committed files in `vectors/` must match the
//! generator exactly, and every vector is also checked independently of the generator: its
//! bytes decode to its JSON, its JSON encodes to its bytes, invalid frames fail with the named
//! error, and quantization samples convert as recorded.
//!
//! Regenerate with: `cargo run -p protocol --bin gen_vectors`

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use protocol::frame::{decode_frame, encode_frame, Message};
use protocol::quant::Field;
use protocol::vectors::{
    self, FramesFile, InvalidFile, MessageFile, QuantFile, CLIENT_TO_SERVER, SERVER_TO_CLIENT,
};
use protocol::{
    ChatItem, ClientMsg, LobbyCommand, LobbyEvent, RoomEvent, RoomHostCommand, ServerMsg,
};
use serde::de::DeserializeOwned;
use serde::Serialize;

fn dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("vectors")
}

fn read<T: DeserializeOwned>(name: &str) -> T {
    let text = fs::read_to_string(dir().join(name)).unwrap_or_else(|e| panic!("{name}: {e}"));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("{name}: {e}"))
}

fn message_files() -> Vec<(String, MessageFile)> {
    let mut out = Vec::new();
    for entry in fs::read_dir(dir()).unwrap() {
        let name = entry.unwrap().file_name().to_string_lossy().into_owned();
        if name.starts_with("c2s_") || name.starts_with("s2c_") {
            out.push((name.clone(), read::<MessageFile>(&name)));
        }
    }
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

#[test]
fn committed_vectors_match_the_generator() {
    let problems = vectors::diff_dir(&dir()).unwrap();
    assert!(
        problems.is_empty(),
        "golden vectors drifted: {problems:?}\nregenerate with: cargo run -p protocol --bin gen_vectors"
    );
}

fn check_vector<M>(file: &str, name: &str, message: &serde_json::Value, hex_str: &str, type_id: u8)
where
    M: Message + Serialize + DeserializeOwned + PartialEq + std::fmt::Debug,
{
    let bytes = hex::decode(hex_str).unwrap();
    assert_eq!(bytes.first(), Some(&type_id), "{file}/{name}: type byte");
    let decoded: Vec<M> = decode_frame(&bytes).unwrap_or_else(|e| panic!("{file}/{name}: {e}"));
    assert_eq!(decoded.len(), 1, "{file}/{name}");
    assert_eq!(
        &serde_json::to_value(&decoded[0]).unwrap(),
        message,
        "{file}/{name}: decode"
    );
    let from_json: M =
        serde_json::from_value(message.clone()).unwrap_or_else(|e| panic!("{file}/{name}: {e}"));
    let encoded = encode_frame(&[from_json]).unwrap();
    assert_eq!(hex::encode(&encoded), hex_str, "{file}/{name}: encode");
}

#[test]
fn every_message_vector_decodes_and_encodes_exactly() {
    let files = message_files();
    assert!(!files.is_empty());
    for (fname, file) in &files {
        assert_eq!(file.protocol_version, protocol::PROTOCOL_VERSION);
        assert!(!file.vectors.is_empty(), "{fname}");
        for v in &file.vectors {
            assert_eq!(
                v.message.get("type").and_then(|t| t.as_str()),
                Some(file.type_name.as_str())
            );
            match file.direction.as_str() {
                CLIENT_TO_SERVER => {
                    check_vector::<ClientMsg>(fname, &v.name, &v.message, &v.hex, file.type_id)
                }
                SERVER_TO_CLIENT => {
                    check_vector::<ServerMsg>(fname, &v.name, &v.message, &v.hex, file.type_id)
                }
                other => panic!("{fname}: bad direction {other}"),
            }
        }
    }
}

#[test]
fn vectors_cover_every_message_and_sub_kind() {
    let mut client = BTreeSet::new();
    let mut server = BTreeSet::new();
    let (mut lobby_cmd, mut lobby_ev, mut room_ev, mut host_cmd, mut chat) = (
        BTreeSet::new(),
        BTreeSet::new(),
        BTreeSet::new(),
        BTreeSet::new(),
        BTreeSet::new(),
    );
    for (_, file) in message_files() {
        for v in &file.vectors {
            let bytes = hex::decode(&v.hex).unwrap();
            if file.direction == CLIENT_TO_SERVER {
                let m = decode_frame::<ClientMsg>(&bytes).unwrap().remove(0);
                client.insert(m.tag());
                match &m {
                    ClientMsg::LobbyCommand(c) => {
                        lobby_cmd.insert(c.tag());
                    }
                    ClientMsg::RoomHostCommand(c) => {
                        host_cmd.insert(c.tag());
                    }
                    ClientMsg::QuickChat(q) => {
                        chat.insert(q.item.tag());
                    }
                    _ => {}
                }
            } else {
                let m = decode_frame::<ServerMsg>(&bytes).unwrap().remove(0);
                server.insert(m.tag());
                match &m {
                    ServerMsg::LobbyEvent(e) => {
                        lobby_ev.insert(e.tag());
                    }
                    ServerMsg::RoomEvent(e) => {
                        room_ev.insert(e.tag());
                    }
                    ServerMsg::QuickChat(q) => {
                        chat.insert(q.item.tag());
                    }
                    _ => {}
                }
            }
        }
    }
    let all = |tags: &[u8]| tags.iter().copied().collect::<BTreeSet<u8>>();
    assert_eq!(client, all(ClientMsg::TAGS));
    assert_eq!(server, all(ServerMsg::TAGS));
    assert_eq!(lobby_cmd, all(LobbyCommand::TAGS));
    assert_eq!(lobby_ev, all(LobbyEvent::TAGS));
    assert_eq!(room_ev, all(RoomEvent::TAGS));
    assert_eq!(host_cmd, all(RoomHostCommand::TAGS));
    assert_eq!(chat, all(ChatItem::TAGS));
}

#[test]
fn frame_vectors_round_trip() {
    let file: FramesFile = read("frames.json");
    assert!(!file.frames.is_empty());
    for f in &file.frames {
        let bytes = hex::decode(&f.hex).unwrap();
        let json: Vec<serde_json::Value> = if f.direction == CLIENT_TO_SERVER {
            let msgs: Vec<ClientMsg> = decode_frame(&bytes).unwrap();
            let again: Vec<ClientMsg> = f
                .messages
                .iter()
                .map(|m| serde_json::from_value(m.clone()).unwrap())
                .collect();
            assert_eq!(
                hex::encode(encode_frame(&again).unwrap()),
                f.hex,
                "{}",
                f.name
            );
            msgs.iter()
                .map(|m| serde_json::to_value(m).unwrap())
                .collect()
        } else {
            let msgs: Vec<ServerMsg> = decode_frame(&bytes).unwrap();
            let again: Vec<ServerMsg> = f
                .messages
                .iter()
                .map(|m| serde_json::from_value(m.clone()).unwrap())
                .collect();
            assert_eq!(
                hex::encode(encode_frame(&again).unwrap()),
                f.hex,
                "{}",
                f.name
            );
            msgs.iter()
                .map(|m| serde_json::to_value(m).unwrap())
                .collect()
        };
        assert_eq!(json, f.messages, "{}", f.name);
    }
}

#[test]
fn invalid_vectors_are_rejected_with_the_named_error() {
    let file: InvalidFile = read("invalid.json");
    assert_eq!(file.max_frame_len, protocol::MAX_FRAME_LEN);
    assert!(file.vectors.len() >= 30);
    for v in &file.vectors {
        let bytes = hex::decode(&v.hex).unwrap();
        let err = if v.direction == CLIENT_TO_SERVER {
            decode_frame::<ClientMsg>(&bytes).map(|_| ()).unwrap_err()
        } else {
            decode_frame::<ServerMsg>(&bytes).map(|_| ()).unwrap_err()
        };
        assert_eq!(err.kind(), v.error, "{}: {err}", v.name);
    }
}

#[test]
fn quantization_vectors_convert_as_recorded() {
    let file: QuantFile = read("quantization.json");
    assert_eq!(file.fields.len(), Field::ALL.len());
    for v in &file.vectors {
        let field = Field::ALL
            .iter()
            .copied()
            .find(|f| f.name() == v.field)
            .unwrap();
        match field.to_wire(v.physical) {
            Ok(w) => {
                assert_eq!(Some(w), v.wire, "{} {}", v.field, v.physical);
                assert_eq!(Some(field.from_wire(w)), v.back);
            }
            Err(_) => assert!(
                v.wire.is_none() && v.error.is_some(),
                "{} {}",
                v.field,
                v.physical
            ),
        }
    }
}
