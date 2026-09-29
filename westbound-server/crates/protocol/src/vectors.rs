//! Golden test vectors (multiplayer handoff → Networking protocol → Golden vectors): every
//! message as JSON plus its exact bytes, multi-message frames, invalid frames with the expected
//! error kind, and quantization samples. The GDScript codec (N2.2) must encode and decode every
//! vector identically.
//!
//! Regenerate the committed files with `cargo run -p protocol --bin gen_vectors`; the
//! `golden_vectors` integration test fails when they drift from this module.

use std::fs;
use std::io;
use std::path::Path;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::frame::{decode_frame, encode_frame, Message};
use crate::messages::*;
use crate::quant::Field;
use crate::types::*;
use crate::wire::Wire;
use crate::{MAX_FRAME_LEN, MAX_MESSAGES_PER_FRAME, PROTOCOL_VERSION};

pub const CLIENT_TO_SERVER: &str = "client_to_server";
pub const SERVER_TO_CLIENT: &str = "server_to_client";

/// One message: its JSON form and its framed bytes (`[type][len][payload]`) as lowercase hex.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MessageVector {
    pub name: String,
    pub message: Value,
    pub hex: String,
}

/// `c2s_<type>.json` / `s2c_<type>.json`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MessageFile {
    pub protocol_version: u16,
    pub direction: String,
    #[serde(rename = "type")]
    pub type_name: String,
    pub type_id: u8,
    pub vectors: Vec<MessageVector>,
}

/// A frame holding several messages.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FrameVector {
    pub name: String,
    pub direction: String,
    pub messages: Vec<Value>,
    pub hex: String,
}

/// `frames.json`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FramesFile {
    pub protocol_version: u16,
    pub frames: Vec<FrameVector>,
}

/// A frame the decoder must reject, with the expected `DecodeError::kind()`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InvalidVector {
    pub name: String,
    pub direction: String,
    pub hex: String,
    pub error: String,
}

/// `invalid.json`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InvalidFile {
    pub protocol_version: u16,
    pub max_frame_len: usize,
    pub max_messages_per_frame: usize,
    pub vectors: Vec<InvalidVector>,
}

/// One field's quantization rule.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct QuantField {
    pub field: String,
    /// Wire units per physical unit.
    pub scale: f64,
    pub wire_min: i64,
    pub wire_max: i64,
    /// `reject`, `clamp` or `wrap_then_clamp`.
    pub out_of_range: String,
}

/// physical → wire (or an error), and wire → physical.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct QuantVector {
    pub field: String,
    pub physical: f64,
    /// `None` when the conversion is rejected.
    pub wire: Option<i64>,
    /// `from_wire(wire)`, when `wire` is present.
    pub back: Option<f64>,
    pub error: Option<String>,
}

/// `quantization.json`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct QuantFile {
    pub protocol_version: u16,
    pub rounding: String,
    pub fields: Vec<QuantField>,
    pub vectors: Vec<QuantVector>,
}

// ---------------------------------------------------------------------------------------------
// Sample values
// ---------------------------------------------------------------------------------------------

fn map_hash() -> MapHash {
    let mut h = [0u8; 32];
    for (i, b) in h.iter_mut().enumerate() {
        *b = (i as u8).wrapping_mul(37).wrapping_add(11);
    }
    MapHash(h)
}

fn name(s: &str) -> DisplayName {
    DisplayName(s.to_owned())
}

fn code(s: &str) -> Code {
    Code(s.to_owned())
}

fn ident(id: u64, n: &str, tag: u16) -> Identity {
    Identity {
        account_id: AccountId(id),
        display_name: name(n),
        name_tag: tag,
    }
}

fn state_typical() -> PlayerState {
    PlayerState {
        tick: 123_456,
        s_mm: 12_345_678,
        d_cm: -175,
        heading_e4: 873,
        speed_cms: 6_944,
        lat_vel_cms: -42,
        yaw_rate_mrad_s: 118,
        steer_e4: -1_250,
        flags: PlayerFlags {
            brake: false,
            boost: true,
            headlights: true,
            ghost: false,
        },
        run_state: RunState::Driving,
    }
}

fn state_max() -> PlayerState {
    PlayerState {
        tick: u32::MAX,
        s_mm: u32::MAX,
        d_cm: MAX_ABS_D_CM,
        heading_e4: MAX_HEADING_E4,
        speed_cms: MAX_SPEED_CMS,
        lat_vel_cms: MAX_ABS_I16,
        yaw_rate_mrad_s: MAX_ABS_I16,
        steer_e4: MAX_STEER_E4,
        flags: PlayerFlags {
            brake: true,
            boost: true,
            headlights: true,
            ghost: true,
        },
        run_state: RunState::Crashed,
    }
}

fn state_min() -> PlayerState {
    PlayerState {
        tick: 0,
        s_mm: 0,
        d_cm: -MAX_ABS_D_CM,
        heading_e4: -MAX_HEADING_E4,
        speed_cms: 0,
        lat_vel_cms: -MAX_ABS_I16,
        yaw_rate_mrad_s: -MAX_ABS_I16,
        steer_e4: -MAX_STEER_E4,
        flags: PlayerFlags::default(),
        run_state: RunState::NotRunning,
    }
}

fn settings_private() -> RoomSettings {
    RoomSettings {
        visibility: Visibility::Private,
        max_players: 8,
        density: Density::Rush,
        time_mode: TimeMode::Fixed,
        fixed_cycle_ms: 1_140_000,
    }
}

fn settings_public() -> RoomSettings {
    RoomSettings {
        visibility: Visibility::Public,
        max_players: 8,
        density: Density::Normal,
        time_mode: TimeMode::Cycle,
        fixed_cycle_ms: 0,
    }
}

fn clock() -> RoomClock {
    RoomClock {
        cycle_ms: 1_000_000,
        cycle_len_ms: 1_920_000,
        day_len_ms: 1_320_000,
    }
}

fn member(pid: u16, id: u64, n: &str, tag: u16, crew: &str, slot: u8, host: bool) -> Member {
    Member {
        player_id: pid,
        identity: ident(id, n, tag),
        crew_tag: CrewTag(crew.to_owned()),
        crew_slot: slot,
        flags: MemberFlags {
            host,
            disconnected: false,
        },
    }
}

fn spawn_typical() -> TrafficSpawnEntry {
    TrafficSpawnEntry {
        car_id: 412,
        vehicle: 3,
        color: 7,
        profile: 1,
        lane: 2,
        s_mm: 13_000_250,
        d_cm: 525,
        speed_cms: 3_056,
        lc_phase: LaneChangePhase::None,
        lc_target_lane: 0,
        lc_move_start_tick: 0,
        lc_duration_ms: 0,
        flags: TrafficFlags::default(),
    }
}

fn spawn_signaling() -> TrafficSpawnEntry {
    TrafficSpawnEntry {
        car_id: 413,
        lc_phase: LaneChangePhase::Signaling,
        lc_target_lane: 1,
        lc_move_start_tick: 123_470,
        lc_duration_ms: 2_400,
        ..spawn_typical()
    }
}

fn spawn_max() -> TrafficSpawnEntry {
    TrafficSpawnEntry {
        car_id: u16::MAX,
        vehicle: u8::MAX,
        color: u8::MAX,
        profile: u8::MAX,
        lane: MAX_LANES - 1,
        s_mm: u32::MAX,
        d_cm: MAX_ABS_D_CM,
        speed_cms: MAX_SPEED_CMS,
        lc_phase: LaneChangePhase::Moving,
        lc_target_lane: MAX_LANES - 1,
        lc_move_start_tick: u32::MAX,
        lc_duration_ms: u16::MAX,
        flags: TrafficFlags {
            hazard: true,
            braking: true,
        },
    }
}

fn intent(
    car: u16,
    kind: IntentKind,
    start: u32,
    mv: u32,
    lane: u8,
    dur: u16,
) -> TrafficIntentEntry {
    TrafficIntentEntry {
        car_id: car,
        kind,
        start_tick: start,
        move_start_tick: mv,
        target_lane: lane,
        duration_ms: dur,
    }
}

fn correction(car: u16, s: u32, d: i16, v: u16) -> CorrectionEntry {
    CorrectionEntry {
        car_id: car,
        s_mm: s,
        d_cm: d,
        speed_cms: v,
    }
}

fn lobby(c: LobbyCommand) -> ClientMsg {
    ClientMsg::LobbyCommand(c)
}

fn lobby_ev(e: LobbyEvent) -> ServerMsg {
    ServerMsg::LobbyEvent(e)
}

fn room_ev(e: RoomEvent) -> ServerMsg {
    ServerMsg::RoomEvent(e)
}

/// Every client → server sample, grouped by message type in wire order.
pub fn client_samples() -> Vec<(&'static str, ClientMsg)> {
    let long_token = "e".repeat(MAX_TOKEN_BYTES);
    vec![
        (
            "typical",
            ClientMsg::Hello(Hello {
                protocol_version: PROTOCOL_VERSION,
                client_build: 10_203,
                map_hash: map_hash(),
                access_token: AccessToken(
                    "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiI0MiJ9.c2lnbmF0dXJl".to_owned(),
                ),
            }),
        ),
        (
            "max_token_and_edges",
            ClientMsg::Hello(Hello {
                protocol_version: u16::MAX,
                client_build: u32::MAX,
                map_hash: MapHash([0xFF; 32]),
                access_token: AccessToken(long_token),
            }),
        ),
        (
            "empty_token",
            ClientMsg::Hello(Hello {
                protocol_version: 0,
                client_build: 0,
                map_hash: MapHash([0; 32]),
                access_token: AccessToken(String::new()),
            }),
        ),
        (
            "typical",
            ClientMsg::Ping(Ping {
                client_time_ms: 5_000_123,
            }),
        ),
        (
            "max",
            ClientMsg::Ping(Ping {
                client_time_ms: u32::MAX,
            }),
        ),
        ("party_create", lobby(LobbyCommand::PartyCreate(Empty {}))),
        (
            "party_invite",
            lobby(LobbyCommand::PartyInvite(AccountRef {
                account_id: AccountId(9_007_199_254_740_993),
            })),
        ),
        (
            "party_join",
            lobby(LobbyCommand::PartyJoin(CodeRef {
                code: code("K7QX2M"),
            })),
        ),
        ("party_leave", lobby(LobbyCommand::PartyLeave(Empty {}))),
        (
            "party_kick_max_account",
            lobby(LobbyCommand::PartyKick(AccountRef {
                account_id: AccountId(MAX_ACCOUNT_ID),
            })),
        ),
        (
            "presence_subscribe",
            lobby(LobbyCommand::PresenceSubscribe(PresenceSubscribe {
                enabled: true,
            })),
        ),
        (
            "presence_unsubscribe",
            lobby(LobbyCommand::PresenceSubscribe(PresenceSubscribe {
                enabled: false,
            })),
        ),
        (
            "room_create",
            lobby(LobbyCommand::RoomCreate(settings_private())),
        ),
        (
            "room_create_night_16",
            lobby(LobbyCommand::RoomCreate(RoomSettings {
                visibility: Visibility::Private,
                max_players: MAX_ROOM_PLAYERS,
                density: Density::Light,
                time_mode: TimeMode::Night,
                fixed_cycle_ms: u32::MAX,
            })),
        ),
        (
            "room_join_code",
            lobby(LobbyCommand::RoomJoinCode(CodeRef {
                code: code("ABC234"),
            })),
        ),
        (
            "room_join_id",
            lobby(LobbyCommand::RoomJoinId(RoomRef { room_id: 77 })),
        ),
        ("room_leave", lobby(LobbyCommand::RoomLeave(Empty {}))),
        ("quick_join", lobby(LobbyCommand::QuickJoin(Empty {}))),
        ("room_browse", lobby(LobbyCommand::RoomBrowse(Empty {}))),
        ("typical", ClientMsg::PlayerState(state_typical())),
        ("max", ClientMsg::PlayerState(state_max())),
        ("min", ClientMsg::PlayerState(state_min())),
        (
            "pass",
            ClientMsg::ScoreClaim(ScoreClaim {
                claim_id: 17,
                tick: 123_460,
                kind: ClaimKind::Pass,
                side: Side::Left,
                cars: vec![ClaimCar {
                    car_id: 412,
                    clearance_mm: 2_150,
                }],
            }),
        ),
        (
            "close_pass",
            ClientMsg::ScoreClaim(ScoreClaim {
                claim_id: 18,
                tick: 123_470,
                kind: ClaimKind::ClosePass,
                side: Side::Right,
                cars: vec![ClaimCar {
                    car_id: 97,
                    clearance_mm: 640,
                }],
            }),
        ),
        (
            "cut",
            ClientMsg::ScoreClaim(ScoreClaim {
                claim_id: 19,
                tick: 123_480,
                kind: ClaimKind::Cut,
                side: Side::None,
                cars: vec![ClaimCar {
                    car_id: 5,
                    clearance_mm: 9_800,
                }],
            }),
        ),
        (
            "thread_max",
            ClientMsg::ScoreClaim(ScoreClaim {
                claim_id: u16::MAX,
                tick: u32::MAX,
                kind: ClaimKind::Thread,
                side: Side::Left,
                cars: vec![
                    ClaimCar {
                        car_id: u16::MAX,
                        clearance_mm: u16::MAX,
                    },
                    ClaimCar {
                        car_id: 0,
                        clearance_mm: 0,
                    },
                ],
            }),
        ),
        (
            "traffic",
            ClientMsg::HitReport(HitReport {
                tick: 124_000,
                target: HitTarget::Traffic,
                car_id: 412,
                lives_left: 1,
            }),
        ),
        (
            "barrier",
            ClientMsg::HitReport(HitReport {
                tick: 124_100,
                target: HitTarget::Barrier,
                car_id: 0,
                lives_left: 0,
            }),
        ),
        (
            "roadside",
            ClientMsg::HitReport(HitReport {
                tick: u32::MAX,
                target: HitTarget::Roadside,
                car_id: 0,
                lives_left: u8::MAX,
            }),
        ),
        (
            "start",
            ClientMsg::RunEvent(RunEvent {
                kind: RunEventKind::Start,
                tick: 100,
            }),
        ),
        (
            "end",
            ClientMsg::RunEvent(RunEvent {
                kind: RunEventKind::End,
                tick: 9_000,
            }),
        ),
        (
            "rejoin",
            ClientMsg::RunEvent(RunEvent {
                kind: RunEventKind::Rejoin,
                tick: u32::MAX,
            }),
        ),
        (
            "phrase",
            ClientMsg::QuickChat(QuickChat {
                item: ChatItem::Phrase(PhraseItem {
                    phrase: Phrase::NiceThread,
                }),
            }),
        ),
        (
            "phrase_one_more_lap",
            ClientMsg::QuickChat(QuickChat {
                item: ChatItem::Phrase(PhraseItem {
                    phrase: Phrase::OneMoreLap,
                }),
            }),
        ),
        (
            "horn",
            ClientMsg::QuickChat(QuickChat {
                item: ChatItem::Horn(Empty {}),
            }),
        ),
        (
            "emote_max",
            ClientMsg::QuickChat(QuickChat {
                item: ChatItem::Emote(EmoteItem { emote: MAX_EMOTE }),
            }),
        ),
        (
            "kick",
            ClientMsg::RoomHostCommand(RoomHostCommand::Kick(PlayerRef { player_id: 3 })),
        ),
        (
            "set_density",
            ClientMsg::RoomHostCommand(RoomHostCommand::SetDensity(SetDensity {
                density: Density::Rush,
            })),
        ),
        (
            "set_time_mode",
            ClientMsg::RoomHostCommand(RoomHostCommand::SetTimeMode(SetTimeMode {
                time_mode: TimeMode::Fixed,
                fixed_cycle_ms: 1_500_000,
            })),
        ),
    ]
}

/// Every server → client sample, grouped by message type in wire order.
pub fn server_samples() -> Vec<(&'static str, ServerMsg)> {
    let full_party: Vec<Identity> = (0..u64::from(MAX_PARTY_MEMBERS))
        .map(|i| ident(1_000 + i, "🚗💨🚗💨🚗💨🚗💨🚗💨🚗💨🚗💨🚗💨", 9_999))
        .collect();
    vec![
        (
            "typical",
            ServerMsg::Welcome(Welcome {
                protocol_version: PROTOCOL_VERSION,
                server_build: 42,
                account_id: AccountId(42),
                tick_rate_hz: 20,
                ping_interval_ms: 2_000,
                timeout_ms: 8_000,
                max_frame_bytes: MAX_FRAME_LEN as u16,
            }),
        ),
        (
            "max",
            ServerMsg::Welcome(Welcome {
                protocol_version: u16::MAX,
                server_build: u32::MAX,
                account_id: AccountId(MAX_ACCOUNT_ID),
                tick_rate_hz: MAX_TICK_RATE_HZ,
                ping_interval_ms: u16::MAX,
                timeout_ms: u16::MAX,
                max_frame_bytes: u16::MAX,
            }),
        ),
        (
            "typical",
            ServerMsg::Pong(Pong {
                client_time_ms: 5_000_123,
                server_tick: 123_456,
                tick_fraction: 32_768,
            }),
        ),
        (
            "max",
            ServerMsg::Pong(Pong {
                client_time_ms: u32::MAX,
                server_tick: u32::MAX,
                tick_fraction: u16::MAX,
            }),
        ),
        (
            "update_required",
            ServerMsg::Error(ErrorMsg {
                code: ErrorCode::UpdateRequired,
                fatal: true,
                detail: Text("Please update Westbound to play online.".to_owned()),
            }),
        ),
        (
            "map_mismatch",
            ServerMsg::Error(ErrorMsg {
                code: ErrorCode::MapMismatch,
                fatal: true,
                detail: Text("Your map data is out of date. Please update Westbound.".to_owned()),
            }),
        ),
        (
            "room_full_nonfatal_empty_detail",
            ServerMsg::Error(ErrorMsg {
                code: ErrorCode::RoomFull,
                fatal: false,
                detail: Text(String::new()),
            }),
        ),
        (
            "internal_max_detail",
            ServerMsg::Error(ErrorMsg {
                code: ErrorCode::Internal,
                fatal: true,
                detail: Text("é".repeat(MAX_TEXT_BYTES / 2) + "\n"),
            }),
        ),
        (
            "party_state",
            lobby_ev(LobbyEvent::PartyState(PartyState {
                code: code("PARTY9"),
                leader: AccountId(42),
                members: vec![
                    ident(42, "Dusty", 1_234),
                    ident(77, "Zoë", 7),
                    ident(78, "東京ドリフト", 0),
                ],
            })),
        ),
        (
            "party_state_full",
            lobby_ev(LobbyEvent::PartyState(PartyState {
                code: code("ZZZZZZ"),
                leader: AccountId(1_000),
                members: full_party,
            })),
        ),
        (
            "party_left",
            lobby_ev(LobbyEvent::PartyLeft(PartyLeft {
                reason: PartyLeftReason::Disbanded,
            })),
        ),
        (
            "party_invite",
            lobby_ev(LobbyEvent::PartyInvite(PartyInvite {
                from: ident(42, "Dusty", 1_234),
                code: code("PARTY9"),
            })),
        ),
        (
            "presence",
            lobby_ev(LobbyEvent::Presence(Presence {
                friends: vec![
                    FriendPresence {
                        account_id: AccountId(77),
                        status: PresenceStatus::InRoom,
                        room_id: 12,
                        joinable: true,
                    },
                    FriendPresence {
                        account_id: AccountId(78),
                        status: PresenceStatus::Offline,
                        room_id: 0,
                        joinable: false,
                    },
                ],
            })),
        ),
        (
            "presence_empty",
            lobby_ev(LobbyEvent::Presence(Presence { friends: vec![] })),
        ),
        (
            "room_list",
            lobby_ev(LobbyEvent::RoomList(RoomList {
                rooms: vec![
                    RoomListEntry {
                        room_id: 12,
                        players: 7,
                        max_players: 8,
                        density: Density::Normal,
                        night: true,
                    },
                    RoomListEntry {
                        room_id: u32::MAX,
                        players: 0,
                        max_players: 1,
                        density: Density::Light,
                        night: false,
                    },
                ],
            })),
        ),
        (
            "room_left",
            lobby_ev(LobbyEvent::RoomLeft(RoomLeft {
                reason: RoomLeftReason::Kicked,
            })),
        ),
        (
            "private_room",
            ServerMsg::RoomSnapshot(RoomSnapshot {
                room_id: 12,
                code: code("ABC234"),
                settings: settings_private(),
                tick: 123_456,
                clock: clock(),
                you: 1,
                members: vec![
                    member(0, 42, "Dusty", 1_234, "WB", 0, true),
                    member(1, 77, "Zoë", 7, "", 0, false),
                ],
                crews: vec![RoomCrew {
                    crew_slot: 0,
                    color: 3,
                    session_total: 250_000,
                }],
            }),
        ),
        (
            "public_room",
            ServerMsg::RoomSnapshot(RoomSnapshot {
                room_id: 99,
                code: code("MNPQRS"),
                settings: settings_public(),
                tick: 0,
                clock: RoomClock {
                    cycle_ms: 1_919_999,
                    cycle_len_ms: 1_920_000,
                    day_len_ms: 1_320_000,
                },
                you: 0,
                members: vec![Member {
                    player_id: 0,
                    identity: ident(5, "Solo", 1),
                    crew_tag: CrewTag("ÄÖÜ!".to_owned()),
                    crew_slot: MAX_CREWS - 1,
                    flags: MemberFlags {
                        host: false,
                        disconnected: true,
                    },
                }],
                crews: vec![],
            }),
        ),
        (
            "typical",
            ServerMsg::PlayerStates(PlayerStates {
                players: (1..=7)
                    .map(|p| PlayerStateEntry {
                        player_id: p,
                        state: PlayerState {
                            s_mm: 12_345_678 + u32::from(p) * 9_000,
                            ..state_typical()
                        },
                    })
                    .collect(),
            }),
        ),
        (
            "edges",
            ServerMsg::PlayerStates(PlayerStates {
                players: vec![
                    PlayerStateEntry {
                        player_id: 0,
                        state: state_min(),
                    },
                    PlayerStateEntry {
                        player_id: u16::MAX,
                        state: state_max(),
                    },
                ],
            }),
        ),
        (
            "typical",
            ServerMsg::TrafficSpawn(TrafficSpawn {
                cars: vec![spawn_typical(), spawn_signaling()],
            }),
        ),
        (
            "max",
            ServerMsg::TrafficSpawn(TrafficSpawn {
                cars: vec![spawn_max()],
            }),
        ),
        (
            "typical",
            ServerMsg::TrafficDespawn(TrafficDespawn {
                car_ids: vec![412, 0, u16::MAX],
            }),
        ),
        (
            "full_batch",
            ServerMsg::TrafficDespawn(TrafficDespawn {
                car_ids: (0..u16::from(MAX_TRAFFIC_BATCH)).collect(),
            }),
        ),
        (
            "every_kind",
            ServerMsg::TrafficIntent(TrafficIntent {
                intents: vec![
                    intent(412, IntentKind::LaneChange, 123_456, 123_476, 1, 2_500),
                    intent(412, IntentKind::Cancel, 123_466, 123_466, 0, 0),
                    intent(97, IntentKind::Hazard, 123_500, 123_500, 0, 4_000),
                    intent(98, IntentKind::Horn, 123_501, 123_501, 0, 600),
                    intent(99, IntentKind::HardBrake, 123_502, 123_502, 0, 1_500),
                ],
            }),
        ),
        (
            "max",
            ServerMsg::TrafficIntent(TrafficIntent {
                intents: vec![intent(
                    u16::MAX,
                    IntentKind::LaneChange,
                    u32::MAX,
                    u32::MAX,
                    MAX_LANES - 1,
                    u16::MAX,
                )],
            }),
        ),
        (
            "typical",
            ServerMsg::TrafficCorrection(TrafficCorrection {
                tick: 123_456,
                cars: vec![
                    correction(412, 13_000_250, 525, 3_056),
                    correction(97, 12_990_000, -350, 2_800),
                    correction(98, 13_400_125, 175, 3_333),
                ],
            }),
        ),
        (
            "edges",
            ServerMsg::TrafficCorrection(TrafficCorrection {
                tick: u32::MAX,
                cars: vec![
                    correction(0, 0, -MAX_ABS_D_CM, 0),
                    correction(u16::MAX, u32::MAX, MAX_ABS_D_CM, MAX_SPEED_CMS),
                ],
            }),
        ),
        (
            "typical",
            ServerMsg::ScoreSync(ScoreSync {
                tick: 123_460,
                run_seq: 3,
                banked: 125_000,
                chain: 4_200,
                multiplier_milli: 12_500,
                lives: 2,
                crew_in_range: 2,
                flags: ScoreFlags {
                    banking: false,
                    night: true,
                    unverified: false,
                },
            }),
        ),
        (
            "banking_max",
            ServerMsg::ScoreSync(ScoreSync {
                tick: u32::MAX,
                run_seq: u16::MAX,
                banked: u32::MAX,
                chain: u32::MAX,
                multiplier_milli: u32::MAX,
                lives: u8::MAX,
                crew_in_range: MAX_ROOM_PLAYERS,
                flags: ScoreFlags {
                    banking: true,
                    night: true,
                    unverified: true,
                },
            }),
        ),
        (
            "train",
            ServerMsg::ScoreEvent(ScoreEvent {
                tick: 123_470,
                player_id: 1,
                kind: ScoreEventKind::Train,
                points: 25,
                multiplier_gain_milli: 2_000,
                link: 3,
                sector: 0,
                ref_id: 412,
            }),
        ),
        (
            "sector_clean",
            ServerMsg::ScoreEvent(ScoreEvent {
                tick: 130_000,
                player_id: 0,
                kind: ScoreEventKind::SectorClean,
                points: 5_000,
                multiplier_gain_milli: 0,
                link: 0,
                sector: 5,
                ref_id: 0,
            }),
        ),
        (
            "claim_rejected",
            ServerMsg::ScoreEvent(ScoreEvent {
                tick: u32::MAX,
                player_id: u16::MAX,
                kind: ScoreEventKind::ClaimRejected,
                points: 0,
                multiplier_gain_milli: 0,
                link: 0,
                sector: 0,
                ref_id: u16::MAX,
            }),
        ),
        (
            "crashed",
            ServerMsg::RunResult(RunResult {
                player_id: 1,
                run_seq: 3,
                end_reason: RunEndReason::Crashed,
                flags: RunResultFlags {
                    verified: true,
                    leaderboard_eligible: true,
                },
                score: 1_250_000,
                duration_ms: 452_000,
                distance_m: 24_800,
                passes: 310,
                close_passes: 64,
                cuts: 41,
                threads: 12,
                trains: 7,
                max_multiplier_milli: 48_250,
            }),
        ),
        (
            "max",
            ServerMsg::RunResult(RunResult {
                player_id: u16::MAX,
                run_seq: u16::MAX,
                end_reason: RunEndReason::RoomClosed,
                flags: RunResultFlags::default(),
                score: u32::MAX,
                duration_ms: u32::MAX,
                distance_m: u32::MAX,
                passes: u16::MAX,
                close_passes: u16::MAX,
                cuts: u16::MAX,
                threads: u16::MAX,
                trains: u16::MAX,
                max_multiplier_milli: u32::MAX,
            }),
        ),
        (
            "join",
            room_ev(RoomEvent::Join(member(
                2,
                78,
                "東京ドリフト",
                0,
                "JDM",
                1,
                false,
            ))),
        ),
        (
            "leave",
            room_ev(RoomEvent::Leave(MemberLeft {
                player_id: 2,
                reason: LeaveReason::TimedOut,
            })),
        ),
        (
            "host_change",
            room_ev(RoomEvent::HostChange(PlayerRef { player_id: 1 })),
        ),
        ("kick", room_ev(RoomEvent::Kick(PlayerRef { player_id: 2 }))),
        (
            "settings",
            room_ev(RoomEvent::Settings(SettingsChanged {
                tick: 130_000,
                settings: RoomSettings {
                    time_mode: TimeMode::Night,
                    ..settings_private()
                },
                clock: clock(),
            })),
        ),
        (
            "crew",
            room_ev(RoomEvent::Crew(RoomCrew {
                crew_slot: 1,
                color: 9,
                session_total: u32::MAX,
            })),
        ),
        (
            "connection",
            room_ev(RoomEvent::Connection(MemberConnection {
                player_id: 1,
                connected: false,
            })),
        ),
        (
            "phrase",
            ServerMsg::QuickChat(QuickChatRelay {
                player_id: 1,
                item: ChatItem::Phrase(PhraseItem {
                    phrase: Phrase::Regroup,
                }),
            }),
        ),
        (
            "horn",
            ServerMsg::QuickChat(QuickChatRelay {
                player_id: 2,
                item: ChatItem::Horn(Empty {}),
            }),
        ),
        (
            "emote",
            ServerMsg::QuickChat(QuickChatRelay {
                player_id: u16::MAX,
                item: ChatItem::Emote(EmoteItem { emote: 0 }),
            }),
        ),
        (
            "restart",
            ServerMsg::ServerNotice(ServerNotice {
                kind: NoticeKind::Restart,
                seconds: 60,
                text: Text("Server restarting in 60 seconds.".to_owned()),
            }),
        ),
        (
            "info_empty",
            ServerMsg::ServerNotice(ServerNotice {
                kind: NoticeKind::Info,
                seconds: 0,
                text: Text(String::new()),
            }),
        ),
        (
            "maintenance_max",
            ServerMsg::ServerNotice(ServerNotice {
                kind: NoticeKind::Maintenance,
                seconds: u16::MAX,
                text: Text("x".repeat(MAX_TEXT_BYTES)),
            }),
        ),
    ]
}

// ---------------------------------------------------------------------------------------------
// Generation
// ---------------------------------------------------------------------------------------------

fn json<T: Serialize>(v: &T) -> Value {
    serde_json::to_value(v).expect("vector samples serialize")
}

fn type_name(v: &Value) -> String {
    v.get("type")
        .and_then(Value::as_str)
        .expect("messages carry a type tag")
        .to_owned()
}

fn encode_one<M: Message>(m: &M) -> Vec<u8> {
    encode_frame(std::slice::from_ref(m))
        .expect("vector samples are valid")
        .to_vec()
}

fn message_files<M>(
    prefix: &str,
    direction: &str,
    samples: Vec<(&'static str, M)>,
) -> Vec<(String, MessageFile)>
where
    M: Message + Serialize + PartialEq + std::fmt::Debug,
{
    let mut files: Vec<(String, MessageFile)> = Vec::new();
    for (name, msg) in samples {
        let value = json(&msg);
        let bytes = encode_one(&msg);
        let back: Vec<M> = decode_frame(&bytes).expect("vector samples decode");
        assert_eq!(
            back.as_slice(),
            std::slice::from_ref(&msg),
            "vector {name} round-trips"
        );
        let tname = type_name(&value);
        let file_name = format!("{prefix}_{tname}.json");
        let vector = MessageVector {
            name: name.to_owned(),
            message: value,
            hex: hex::encode(&bytes),
        };
        match files.iter_mut().find(|(f, _)| *f == file_name) {
            Some((_, file)) => file.vectors.push(vector),
            None => files.push((
                file_name,
                MessageFile {
                    protocol_version: PROTOCOL_VERSION,
                    direction: direction.to_owned(),
                    type_name: tname,
                    type_id: msg.type_id(),
                    vectors: vec![vector],
                },
            )),
        }
    }
    files
}

fn frames_file() -> FramesFile {
    let client_frame = vec![
        ClientMsg::PlayerState(state_typical()),
        ClientMsg::Ping(Ping { client_time_ms: 77 }),
        ClientMsg::ScoreClaim(ScoreClaim {
            claim_id: 1,
            tick: 123_456,
            kind: ClaimKind::Pass,
            side: Side::Right,
            cars: vec![ClaimCar {
                car_id: 3,
                clearance_mm: 1_900,
            }],
        }),
    ];
    let tick_frame = vec![
        ServerMsg::PlayerStates(PlayerStates {
            players: vec![PlayerStateEntry {
                player_id: 1,
                state: state_typical(),
            }],
        }),
        ServerMsg::TrafficCorrection(TrafficCorrection {
            tick: 123_456,
            cars: vec![correction(412, 13_000_250, 525, 3_056)],
        }),
        ServerMsg::TrafficIntent(TrafficIntent {
            intents: vec![intent(
                412,
                IntentKind::LaneChange,
                123_456,
                123_476,
                1,
                2_500,
            )],
        }),
        ServerMsg::ScoreSync(ScoreSync {
            tick: 123_456,
            ..ScoreSync::default()
        }),
    ];
    let split_batches = vec![
        ServerMsg::TrafficDespawn(TrafficDespawn {
            car_ids: vec![1, 2],
        }),
        ServerMsg::TrafficDespawn(TrafficDespawn { car_ids: vec![3] }),
    ];
    let frames = vec![
        frame_vector("client_tick", CLIENT_TO_SERVER, &client_frame),
        frame_vector("server_tick", SERVER_TO_CLIENT, &tick_frame),
        frame_vector("same_type_twice", SERVER_TO_CLIENT, &split_batches),
    ];
    FramesFile {
        protocol_version: PROTOCOL_VERSION,
        frames,
    }
}

fn frame_vector<M: Message + Serialize + PartialEq + std::fmt::Debug>(
    name: &str,
    direction: &str,
    msgs: &[M],
) -> FrameVector {
    let bytes = encode_frame(msgs).expect("frame samples are valid");
    let back: Vec<M> = decode_frame(&bytes).expect("frame samples decode");
    assert_eq!(back.as_slice(), msgs);
    FrameVector {
        name: name.to_owned(),
        direction: direction.to_owned(),
        messages: msgs.iter().map(json).collect(),
        hex: hex::encode(&bytes),
    }
}

/// `[type][len][payload]` for an arbitrary payload (no validation).
fn raw(ty: u8, payload: &[u8]) -> Vec<u8> {
    let mut v = vec![ty];
    v.extend_from_slice(&(payload.len() as u16).to_le_bytes());
    v.extend_from_slice(payload);
    v
}

/// The payload of a message, written without validation.
fn body<T: Wire>(t: &T) -> Vec<u8> {
    let mut v = Vec::new();
    t.write(&mut v);
    v
}

fn invalid_file() -> InvalidFile {
    let c = CLIENT_TO_SERVER;
    let s = SERVER_TO_CLIENT;
    let ps = body(&state_typical());
    let hello = Hello {
        protocol_version: PROTOCOL_VERSION,
        client_build: 1,
        map_hash: map_hash(),
        access_token: AccessToken("abc".to_owned()),
    };
    let with_state = |f: &dyn Fn(&mut PlayerState)| {
        let mut st = state_typical();
        f(&mut st);
        raw(type_id::PLAYER_STATE, &body(&st))
    };
    let claim = |n: usize| {
        let st = ScoreClaim {
            claim_id: 1,
            tick: 1,
            kind: ClaimKind::Thread,
            side: Side::Left,
            cars: vec![ClaimCar::default(); n],
        };
        raw(type_id::SCORE_CLAIM, &body(&st))
    };
    let mut bad_utf8_token = vec![0x01, 0x00, 0x01, 0x00, 0x00, 0x00];
    bad_utf8_token.extend_from_slice(&map_hash().0);
    bad_utf8_token.extend_from_slice(&[0x02, 0x00, 0xC3, 0x28]);
    let hello_long_token = body(&Hello {
        access_token: AccessToken("a".repeat(MAX_TOKEN_BYTES + 1)),
        ..hello.clone()
    });
    let hello_space = body(&Hello {
        access_token: AccessToken("a b".to_owned()),
        ..hello.clone()
    });
    let many_pings: Vec<u8> = (0..=MAX_MESSAGES_PER_FRAME)
        .flat_map(|_| raw(type_id::PING, &[0, 0, 0, 0]))
        .collect();
    let mut ping_then_junk = raw(type_id::PING, &[1, 0, 0, 0]);
    ping_then_junk.extend_from_slice(&[type_id::PING, 4, 0, 1]);
    let too_many_corrections = TrafficCorrection {
        tick: 1,
        cars: vec![CorrectionEntry::default(); usize::from(MAX_TRAFFIC_BATCH) + 1],
    };
    let party = |members: Vec<Identity>, code_s: &str| {
        lobby_body(&LobbyEvent::PartyState(PartyState {
            code: code(code_s),
            leader: AccountId(1),
            members,
        }))
    };
    let err_utf8 = raw(
        type_id::ERROR,
        &[ErrorCode::Internal.to_u8(), 1, 2, 0xFF, 0xFE],
    );

    let v = |name: &str, direction: &str, bytes: Vec<u8>, error: &str| InvalidVector {
        name: name.to_owned(),
        direction: direction.to_owned(),
        hex: hex::encode(bytes),
        error: error.to_owned(),
    };

    let vectors = vec![
        v("empty_frame", c, vec![], "empty_frame"),
        v("empty_frame", s, vec![], "empty_frame"),
        v(
            "frame_too_large",
            c,
            vec![0; MAX_FRAME_LEN + 1],
            "frame_too_large",
        ),
        v(
            "truncated_header",
            c,
            vec![type_id::PLAYER_STATE, 22],
            "truncated",
        ),
        v(
            "truncated_payload",
            c,
            raw(type_id::PLAYER_STATE, &ps)[..3 + 10].to_vec(),
            "truncated",
        ),
        v(
            "payload_shorter_than_message",
            c,
            raw(type_id::PLAYER_STATE, &ps[..10]),
            "truncated",
        ),
        v(
            "trailing_bytes",
            c,
            raw(type_id::PING, &[1, 2, 3, 4, 5]),
            "trailing_bytes",
        ),
        v(
            "server_type_sent_to_server",
            c,
            raw(type_id::WELCOME, &[]),
            "unknown_type",
        ),
        v(
            "client_type_sent_to_client",
            s,
            raw(type_id::HELLO, &[]),
            "unknown_type",
        ),
        v("type_zero", c, raw(0x00, &[]), "unknown_type"),
        v("type_ff", s, raw(0xFF, &[]), "unknown_type"),
        v(
            "bad_run_state",
            c,
            {
                let mut b = raw(type_id::PLAYER_STATE, &ps);
                if let Some(last) = b.last_mut() {
                    *last = 9;
                }
                b
            },
            "invalid_enum",
        ),
        v(
            "bad_lobby_kind",
            c,
            raw(type_id::LOBBY_COMMAND, &[200]),
            "invalid_enum",
        ),
        v(
            "bad_bool",
            c,
            raw(type_id::LOBBY_COMMAND, &[5, 2]),
            "invalid_bool",
        ),
        v(
            "reserved_flag_bits",
            c,
            {
                let mut b = raw(type_id::PLAYER_STATE, &ps);
                let n = b.len();
                if let Some(flags) = b.get_mut(n - 2) {
                    *flags |= 0x10;
                }
                b
            },
            "reserved_bits",
        ),
        v(
            "token_bad_utf8",
            c,
            raw(type_id::HELLO, &bad_utf8_token),
            "invalid_utf8",
        ),
        v("detail_bad_utf8", s, err_utf8, "invalid_utf8"),
        v(
            "heading_over_pi",
            c,
            with_state(&|st| st.heading_e4 = MAX_HEADING_E4 + 1),
            "out_of_range",
        ),
        v(
            "d_over_100m",
            c,
            with_state(&|st| st.d_cm = -MAX_ABS_D_CM - 1),
            "out_of_range",
        ),
        v(
            "speed_over_max",
            c,
            with_state(&|st| st.speed_cms = MAX_SPEED_CMS + 1),
            "out_of_range",
        ),
        v(
            "steer_over_one",
            c,
            with_state(&|st| st.steer_e4 = MAX_STEER_E4 + 1),
            "out_of_range",
        ),
        v(
            "lat_vel_i16_min",
            c,
            with_state(&|st| st.lat_vel_cms = i16::MIN),
            "out_of_range",
        ),
        v("claim_without_cars", c, claim(0), "bad_count"),
        v("claim_three_cars", c, claim(3), "bad_count"),
        v(
            "corrections_over_cap",
            s,
            raw(type_id::TRAFFIC_CORRECTION, &body(&too_many_corrections)),
            "bad_count",
        ),
        v(
            "token_too_long",
            c,
            raw(type_id::HELLO, &hello_long_token),
            "string_too_long",
        ),
        v(
            "token_with_space",
            c,
            raw(type_id::HELLO, &hello_space),
            "bad_char",
        ),
        v(
            "code_too_short",
            c,
            raw(
                type_id::LOBBY_COMMAND,
                &lobby_cmd_body(&LobbyCommand::RoomJoinCode(CodeRef {
                    code: code("ABC23"),
                })),
            ),
            "bad_char_count",
        ),
        v(
            "code_bad_char",
            c,
            raw(
                type_id::LOBBY_COMMAND,
                &lobby_cmd_body(&LobbyCommand::RoomJoinCode(CodeRef {
                    code: code("ABCDE0"),
                })),
            ),
            "bad_char",
        ),
        v(
            "empty_display_name",
            s,
            raw(
                type_id::LOBBY_EVENT,
                &party(vec![ident(1, "", 1)], "ABC234"),
            ),
            "bad_char_count",
        ),
        v(
            "display_name_17_chars",
            s,
            raw(
                type_id::LOBBY_EVENT,
                &party(vec![ident(1, "abcdefghijklmnopq", 1)], "ABC234"),
            ),
            "bad_char_count",
        ),
        v(
            "display_name_newline",
            s,
            raw(
                type_id::LOBBY_EVENT,
                &party(vec![ident(1, "a\nb", 1)], "ABC234"),
            ),
            "bad_char",
        ),
        v(
            "name_tag_over_9999",
            s,
            raw(
                type_id::LOBBY_EVENT,
                &party(vec![ident(1, "abc", 10_000)], "ABC234"),
            ),
            "out_of_range",
        ),
        v(
            "account_id_over_i64_max",
            c,
            raw(
                type_id::LOBBY_COMMAND,
                &lobby_cmd_body(&LobbyCommand::PartyInvite(AccountRef {
                    account_id: AccountId(u64::MAX),
                })),
            ),
            "out_of_range",
        ),
        v("too_many_messages", c, many_pings, "too_many_messages"),
        v("valid_then_truncated", c, ping_then_junk, "truncated"),
    ];

    for iv in &vectors {
        let bytes = hex::decode(&iv.hex).expect("hex");
        let kind = if iv.direction == CLIENT_TO_SERVER {
            decode_frame::<ClientMsg>(&bytes).map(|_| ()).err()
        } else {
            decode_frame::<ServerMsg>(&bytes).map(|_| ()).err()
        };
        assert_eq!(
            kind.map(|e| e.kind()),
            Some(iv.error.as_str()),
            "invalid vector {}",
            iv.name
        );
    }

    InvalidFile {
        protocol_version: PROTOCOL_VERSION,
        max_frame_len: MAX_FRAME_LEN,
        max_messages_per_frame: MAX_MESSAGES_PER_FRAME,
        vectors,
    }
}

fn lobby_body(e: &LobbyEvent) -> Vec<u8> {
    body(e)
}

fn lobby_cmd_body(c: &LobbyCommand) -> Vec<u8> {
    body(c)
}

fn quant_file() -> QuantFile {
    let pi = std::f64::consts::PI;
    let rule = |f: Field| match f {
        Field::S => "reject",
        Field::Heading => "wrap_then_clamp",
        _ => "clamp",
    };
    let fields = Field::ALL
        .iter()
        .map(|&f| {
            let (lo, hi) = f.wire_range();
            QuantField {
                field: f.name().to_owned(),
                scale: f.scale(),
                wire_min: lo,
                wire_max: hi,
                out_of_range: rule(f).to_owned(),
            }
        })
        .collect();
    let samples: Vec<(Field, Vec<f64>)> = vec![
        (
            Field::S,
            vec![
                0.0,
                -0.0004,
                -0.0005,
                0.0005,
                1.2345,
                12_345.678_4,
                25_000.0,
                4_294_967.295,
                4_294_967.296,
                -1.0,
            ],
        ),
        (
            Field::D,
            vec![
                0.0, 0.005, -0.005, 1.75, -3.504, 100.0, -100.0, 100.004, 250.0, -1e9,
            ],
        ),
        (
            Field::Speed,
            vec![0.0, 0.125, 30.555, 69.44, 200.0, 200.01, -3.0, 1e6],
        ),
        (
            Field::Heading,
            vec![
                0.0,
                0.12345,
                -0.00005,
                pi,
                -pi,
                Field::Heading.from_wire(i64::from(MAX_HEADING_E4)),
                3.14165,
                3.2,
                -3.2,
                2.0 * pi + 0.5,
                -7.0,
            ],
        ),
        (
            Field::LatVel,
            vec![0.0, -0.42, 327.67, -327.67, 400.0, -400.0],
        ),
        (Field::YawRate, vec![0.0, 0.1185, -32.767, 32.767, 40.0]),
        (Field::Steer, vec![0.0, -0.125, 1.0, -1.0, 1.5, -2.0]),
        (Field::Clearance, vec![0.0, 0.64, 2.15, 65.535, 70.0, -1.0]),
        (
            Field::Multiplier,
            vec![1.0, 12.5, 999.9995, 0.0, 4_294_967.295, 1e12, -1.0],
        ),
    ];
    let mut vectors = Vec::new();
    for (f, values) in samples {
        for physical in values {
            let (wire, back, error) = match f.to_wire(physical) {
                Ok(w) => (Some(w), Some(f.from_wire(w)), None),
                Err(e) => (
                    None,
                    None,
                    Some(match e {
                        crate::QuantError::NotFinite { .. } => "not_finite".to_owned(),
                        crate::QuantError::OutOfRange { .. } => "out_of_range".to_owned(),
                    }),
                ),
            };
            vectors.push(QuantVector {
                field: f.name().to_owned(),
                physical,
                wire,
                back,
                error,
            });
        }
    }
    QuantFile {
        protocol_version: PROTOCOL_VERSION,
        rounding: "half_away_from_zero".to_owned(),
        fields,
        vectors,
    }
}

fn pretty<T: Serialize>(v: &T) -> String {
    let mut s = serde_json::to_string_pretty(v).expect("vector files serialize");
    s.push('\n');
    s
}

/// Every vector file as `(file name, contents)`, in a stable order.
pub fn generate() -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    for (name, file) in message_files("c2s", CLIENT_TO_SERVER, client_samples()) {
        out.push((name, pretty(&file)));
    }
    for (name, file) in message_files("s2c", SERVER_TO_CLIENT, server_samples()) {
        out.push((name, pretty(&file)));
    }
    out.push(("frames.json".to_owned(), pretty(&frames_file())));
    out.push(("invalid.json".to_owned(), pretty(&invalid_file())));
    out.push(("quantization.json".to_owned(), pretty(&quant_file())));
    out
}

/// Writes every vector file into `dir` and removes stale `*.json` files.
pub fn write_all(dir: &Path) -> io::Result<usize> {
    fs::create_dir_all(dir)?;
    let files = generate();
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        let stale = path.extension().is_some_and(|e| e == "json")
            && !files
                .iter()
                .any(|(n, _)| path.file_name().is_some_and(|f| f == n.as_str()));
        if stale {
            fs::remove_file(&path)?;
        }
    }
    for (name, contents) in &files {
        fs::write(dir.join(name), contents)?;
    }
    Ok(files.len())
}

/// Compares `dir` against freshly generated vectors; returns the names of files that differ,
/// are missing or are stale.
pub fn diff_dir(dir: &Path) -> io::Result<Vec<String>> {
    let files = generate();
    let mut problems = Vec::new();
    for (name, contents) in &files {
        match fs::read_to_string(dir.join(name)) {
            Ok(on_disk) if &on_disk == contents => {}
            Ok(_) => problems.push(format!("{name}: differs")),
            Err(_) => problems.push(format!("{name}: missing")),
        }
    }
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        if path.extension().is_some_and(|e| e == "json") {
            let fname = path
                .file_name()
                .map(|f| f.to_string_lossy().into_owned())
                .unwrap_or_default();
            if !files.iter().any(|(n, _)| *n == fname) {
                problems.push(format!("{fname}: stale"));
            }
        }
    }
    Ok(problems)
}
