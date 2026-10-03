//! Every message of the realtime protocol (multiplayer handoff → Networking protocol; contents
//! from Traffic → What the server sends, Players, Scoring in multiplayer, Rooms, parties and
//! matchmaking, and Time of day in multiplayer). The catalogue is documented in
//! `docs/PROTOCOL.md`; this file freezes after N2 (orchestrator-owned afterwards).
//!
//! Field naming carries the wire unit: `_mm`, `_cm`, `_cms` (cm/s), `_e4` (×1e-4),
//! `_mrad_s` (mrad/s), `_ms`, `_milli` (×1e-3). Conversions live in `quant`.

use crate::types::*;

// ---------------------------------------------------------------------------------------------
// Validation bounds (protocol sanity limits, not gameplay tuning)
// ---------------------------------------------------------------------------------------------

/// Lane indices are 0..MAX_LANES-1 (0 = rightmost lane).
pub const MAX_LANES: u8 = 8;
/// |d| bound: 100 m either side of the centerline.
pub const MAX_ABS_D_CM: i16 = 10_000;
/// Speed bound: 200 m/s (720 km/h).
pub const MAX_SPEED_CMS: u16 = 20_000;
/// |heading| bound: π rad in 1e-4 rad units.
pub const MAX_HEADING_E4: i16 = 31_416;
/// |steer| bound: 1.0 in 1e-4 units.
pub const MAX_STEER_E4: i16 = 10_000;
/// Symmetric i16 bound for lateral velocity and yaw rate (i16::MIN is rejected).
pub const MAX_ABS_I16: i16 = i16::MAX;
/// Name tags are the `#0000`–`#9999` suffix.
pub const MAX_NAME_TAG: u16 = 9_999;
/// Room size cap on the wire (the spec's rooms hold 8; headroom for later).
pub const MAX_ROOM_PLAYERS: u8 = 16;
/// Scoring crews per room; crew slots are 0..MAX_CREWS-1.
pub const MAX_CREWS: u8 = 16;
/// Party size cap on the wire (the spec's parties hold 8).
pub const MAX_PARTY_MEMBERS: u8 = 16;
/// Items per traffic spawn / despawn / correction batch.
pub const MAX_TRAFFIC_BATCH: u8 = 128;
/// Items per traffic intent batch.
pub const MAX_INTENT_BATCH: u8 = 64;
/// Cars per score claim (a thread names two).
pub const MAX_CLAIM_CARS: u8 = 2;
/// Friends per presence message (the server splits longer lists).
pub const MAX_PRESENCE_BATCH: u8 = 128;
/// Rooms per room-list message.
pub const MAX_ROOM_LIST: u8 = 64;
/// Emote indices are 0..=MAX_EMOTE.
pub const MAX_EMOTE: u8 = 31;
/// Server tick rate bound in `Welcome`.
pub const MAX_TICK_RATE_HZ: u8 = 120;

/// Message type ids (the frame's `u8 type`). Client→server ids are 0x01–0x3F, server→client
/// ids are 0x40–0x7F. `HELLO`, `WELCOME` and `ERROR` are frozen forever (see versioning rules).
pub mod type_id {
    pub const HELLO: u8 = 0x01;
    pub const PING: u8 = 0x02;
    pub const LOBBY_COMMAND: u8 = 0x03;
    pub const PLAYER_STATE: u8 = 0x04;
    pub const SCORE_CLAIM: u8 = 0x05;
    pub const HIT_REPORT: u8 = 0x06;
    pub const RUN_EVENT: u8 = 0x07;
    pub const QUICK_CHAT: u8 = 0x08;
    pub const ROOM_HOST_COMMAND: u8 = 0x09;

    pub const WELCOME: u8 = 0x40;
    pub const PONG: u8 = 0x41;
    pub const ERROR: u8 = 0x42;
    pub const LOBBY_EVENT: u8 = 0x43;
    pub const ROOM_SNAPSHOT: u8 = 0x44;
    pub const PLAYER_STATES: u8 = 0x45;
    pub const TRAFFIC_SPAWN: u8 = 0x46;
    pub const TRAFFIC_DESPAWN: u8 = 0x47;
    pub const TRAFFIC_INTENT: u8 = 0x48;
    pub const TRAFFIC_CORRECTION: u8 = 0x49;
    pub const SCORE_SYNC: u8 = 0x4A;
    pub const SCORE_EVENT: u8 = 0x4B;
    pub const RUN_RESULT: u8 = 0x4C;
    pub const ROOM_EVENT: u8 = 0x4D;
    pub const QUICK_CHAT_RELAY: u8 = 0x4E;
    pub const SERVER_NOTICE: u8 = 0x4F;
}

// ---------------------------------------------------------------------------------------------
// Shared structures
// ---------------------------------------------------------------------------------------------

wire_struct! {
    /// Who a player is: account, display name and `#tag`.
    pub struct Identity {
        pub account_id: AccountId,
        pub display_name: DisplayName,
        pub name_tag: u16 => range(0, MAX_NAME_TAG),
    }
}

wire_struct! {
    /// Room settings (create, snapshot, settings change).
    pub struct RoomSettings {
        pub visibility: Visibility,
        pub max_players: u8 => range(1, MAX_ROOM_PLAYERS),
        pub density: Density,
        pub time_mode: TimeMode,
        /// Clock position used when `time_mode` is `fixed` (ms into the cycle).
        pub fixed_cycle_ms: u32,
    }
}

wire_struct! {
    /// The room clock at a reference tick: position in the day/night cycle and its shape.
    /// Clients advance `cycle_ms` with server time when the mode is `cycle`.
    pub struct RoomClock {
        /// Position in the cycle at the reference tick, ms (0 = start of morning).
        pub cycle_ms: u32,
        /// Full cycle length, ms (spec: 32 min).
        pub cycle_len_ms: u32,
        /// Day part of the cycle, ms (spec: 22 min); night is the rest.
        pub day_len_ms: u32,
    }
}

wire_struct! {
    /// A player's car state. Sent by the client at 20 Hz (`PlayerState`) and relayed by the
    /// server inside `PlayerStates`. 22 bytes.
    pub struct PlayerState {
        /// Room tick this state belongs to (from `server_now()`).
        pub tick: u32,
        /// Position along the loop, mm.
        pub s_mm: u32,
        /// Lateral offset, cm (positive = left of the centerline).
        pub d_cm: i16 => range(-MAX_ABS_D_CM, MAX_ABS_D_CM),
        /// Heading relative to the road, 1e-4 rad.
        pub heading_e4: i16 => range(-MAX_HEADING_E4, MAX_HEADING_E4),
        /// Speed along the heading, cm/s.
        pub speed_cms: u16 => range(0, MAX_SPEED_CMS),
        /// Lateral velocity, cm/s (±327.67 m/s).
        pub lat_vel_cms: i16 => range(-MAX_ABS_I16, MAX_ABS_I16),
        /// Yaw rate, mrad/s (±32.767 rad/s).
        pub yaw_rate_mrad_s: i16 => range(-MAX_ABS_I16, MAX_ABS_I16),
        /// Steering input, 1e-4 (±1.0).
        pub steer_e4: i16 => range(-MAX_STEER_E4, MAX_STEER_E4),
        pub flags: PlayerFlags,
        pub run_state: RunState,
    }
}

// ---------------------------------------------------------------------------------------------
// Client → server
// ---------------------------------------------------------------------------------------------

wire_struct! {
    /// First message on every connection. Layout frozen: `protocol_version` is always the
    /// first two payload bytes so any server can answer "please update".
    pub struct Hello {
        pub protocol_version: u16,
        pub client_build: u32,
        /// SHA-256 of the client's road-space file.
        pub map_hash: MapHash,
        /// Access token from the HTTP API.
        pub access_token: AccessToken,
    }
}

wire_struct! {
    /// Keepalive and clock-sync probe, every 2 s.
    pub struct Ping {
        /// Client's local monotonic clock, ms (wrapping); echoed in `Pong`.
        pub client_time_ms: u32,
    }
}

wire_struct! {
    pub struct AccountRef {
        pub account_id: AccountId,
    }
}

wire_struct! {
    pub struct CodeRef {
        pub code: Code,
    }
}

wire_struct! {
    pub struct RoomRef {
        pub room_id: u32,
    }
}

wire_struct! {
    pub struct PresenceSubscribe {
        /// `true`: send a presence snapshot now and updates as they happen; `false`: stop.
        pub enabled: bool,
    }
}

wire_union! {
    /// Lobby requests: party, friends presence, rooms, Quick Join. JSON tag: `kind`.
    #[serde(tag = "kind", rename_all = "snake_case")]
    pub enum LobbyCommand {
        PartyCreate(Empty) = 0,
        /// Invite an online friend to your party.
        PartyInvite(AccountRef) = 1,
        /// Join a party by its code (also how an invite is accepted).
        PartyJoin(CodeRef) = 2,
        PartyLeave(Empty) = 3,
        /// Leader only.
        PartyKick(AccountRef) = 4,
        PresenceSubscribe(PresenceSubscribe) = 5,
        /// Create a private room (the server rejects `visibility: public`).
        RoomCreate(RoomSettings) = 6,
        RoomJoinCode(CodeRef) = 7,
        /// Join by id (room browser, a friend's Join button).
        RoomJoinId(RoomRef) = 8,
        RoomLeave(Empty) = 9,
        /// Public room with the most players that fits your whole party.
        QuickJoin(Empty) = 10,
        /// Request the public room list.
        RoomBrowse(Empty) = 11,
        /// Protocol 2: invite an online friend or crewmate to the room you are seated in.
        RoomInvite(AccountRef) = 12,
    }
}

wire_struct! {
    /// One traffic car named in a claim.
    pub struct ClaimCar {
        pub car_id: u16,
        /// Client-measured minimum hull-to-hull clearance, mm.
        pub clearance_mm: u16,
    }
}

wire_struct! {
    /// A locally detected scoring event for server verification.
    pub struct ScoreClaim {
        /// Client counter (wrapping); echoed in `ScoreEvent` rejections.
        pub claim_id: u16,
        pub tick: u32,
        pub kind: ClaimKind,
        /// Side of the passed car (`none` for cuts; threads name the first car's side).
        pub side: Side,
        /// One car, or two for a thread.
        pub cars: Vec<ClaimCar> => count(1, MAX_CLAIM_CARS),
    }
}

wire_struct! {
    /// The client's own hit (the client is authoritative for losing a life).
    pub struct HitReport {
        pub tick: u32,
        pub target: HitTarget,
        /// Traffic car hit; 0 when `target` is not `traffic`.
        pub car_id: u16,
        /// Lives left after the hit.
        pub lives_left: u8,
    }
}

wire_struct! {
    pub struct RunEvent {
        pub kind: RunEventKind,
        pub tick: u32,
    }
}

wire_struct! {
    pub struct PhraseItem {
        pub phrase: Phrase,
    }
}

wire_struct! {
    pub struct EmoteItem {
        pub emote: u8 => range(0, MAX_EMOTE),
    }
}

wire_union! {
    /// A quick-chat item. JSON tag: `kind`.
    #[serde(tag = "kind", rename_all = "snake_case")]
    pub enum ChatItem {
        Phrase(PhraseItem) = 0,
        Horn(Empty) = 1,
        Emote(EmoteItem) = 2,
    }
}

wire_struct! {
    pub struct QuickChat {
        pub item: ChatItem,
    }
}

wire_struct! {
    pub struct PlayerRef {
        pub player_id: u16,
    }
}

wire_struct! {
    pub struct SetDensity {
        pub density: Density,
    }
}

wire_struct! {
    pub struct SetTimeMode {
        pub time_mode: TimeMode,
        pub fixed_cycle_ms: u32,
    }
}

wire_union! {
    /// Private-room host commands. JSON tag: `kind`.
    #[serde(tag = "kind", rename_all = "snake_case")]
    pub enum RoomHostCommand {
        Kick(PlayerRef) = 0,
        SetDensity(SetDensity) = 1,
        SetTimeMode(SetTimeMode) = 2,
    }
}

wire_union! {
    /// Every client → server message. JSON tag: `type`.
    #[serde(tag = "type", rename_all = "snake_case")]
    pub enum ClientMsg {
        Hello(Hello) = type_id::HELLO,
        Ping(Ping) = type_id::PING,
        LobbyCommand(LobbyCommand) = type_id::LOBBY_COMMAND,
        PlayerState(PlayerState) = type_id::PLAYER_STATE,
        ScoreClaim(ScoreClaim) = type_id::SCORE_CLAIM,
        HitReport(HitReport) = type_id::HIT_REPORT,
        RunEvent(RunEvent) = type_id::RUN_EVENT,
        QuickChat(QuickChat) = type_id::QUICK_CHAT,
        RoomHostCommand(RoomHostCommand) = type_id::ROOM_HOST_COMMAND,
    }
}

// ---------------------------------------------------------------------------------------------
// Server → client
// ---------------------------------------------------------------------------------------------

wire_struct! {
    /// Handshake accepted.
    pub struct Welcome {
        /// The server's `PROTOCOL_VERSION`.
        pub protocol_version: u16,
        pub server_build: u32,
        pub account_id: AccountId,
        pub tick_rate_hz: u8 => range(1, MAX_TICK_RATE_HZ),
        /// Send a `Ping` this often.
        pub ping_interval_ms: u16,
        /// The connection is dead after this much silence.
        pub timeout_ms: u16,
        /// Largest frame the server accepts.
        pub max_frame_bytes: u16,
    }
}

wire_struct! {
    /// Answer to `Ping`: the echoed client time plus the server's room clock at send time.
    pub struct Pong {
        pub client_time_ms: u32,
        /// Room tick in progress when the pong was written (0 outside a room).
        pub server_tick: u32,
        /// Progress through that tick, 1/65536 tick. `server_now = server_tick + fraction/65536`.
        pub tick_fraction: u16,
    }
}

wire_struct! {
    /// An error. Layout frozen (code, fatal, detail) so every client can show "please update".
    pub struct ErrorMsg {
        pub code: ErrorCode,
        /// The server closes the connection after sending a fatal error.
        pub fatal: bool,
        /// English detail for logs and fallback UI.
        pub detail: Text,
    }
}

wire_struct! {
    pub struct PartyState {
        pub code: Code,
        pub leader: AccountId,
        pub members: Vec<Identity> => count(1, MAX_PARTY_MEMBERS),
    }
}

wire_struct! {
    pub struct PartyLeft {
        pub reason: PartyLeftReason,
    }
}

wire_struct! {
    pub struct PartyInvite {
        pub from: Identity,
        pub code: Code,
    }
}

wire_struct! {
    /// Protocol 2: a friend or crewmate invites you to the room they are seated in. Accepted
    /// with `room_join_code` and the code; declining needs no message.
    pub struct RoomInvite {
        pub from: Identity,
        pub room_id: u32,
        pub code: Code,
        pub visibility: Visibility,
        /// Seated players when the invite was sent.
        pub players: u8 => range(0, MAX_ROOM_PLAYERS),
        pub max_players: u8 => range(1, MAX_ROOM_PLAYERS),
        /// The invite is shown this long (seconds from receipt).
        pub expires_in_s: u16,
    }
}

wire_struct! {
    /// Protocol 2: a crew invited you (persistent; `GET /api/v1/crews/invites` lists them,
    /// `POST /api/v1/crews/invites/{invite_id}/accept` or `/decline` answers).
    pub struct CrewInvite {
        /// The invite's id (u64 like an account id; JSON: a decimal string).
        pub invite_id: AccountId,
        pub crew_tag: CrewTag,
        /// The crew's name (server-validated: 3–24 characters).
        pub crew_name: Text,
        /// The member who sent it.
        pub from: Identity,
        /// The invite expires this many seconds from receipt.
        pub expires_in_s: u32,
    }
}

wire_struct! {
    pub struct FriendPresence {
        pub account_id: AccountId,
        pub status: PresenceStatus,
        /// Room the friend is in; 0 when none.
        pub room_id: u32,
        /// The friend's room has space for you (shows the Join button).
        pub joinable: bool,
    }
}

wire_struct! {
    /// Presence snapshot or update (same shape; later entries replace earlier ones).
    pub struct Presence {
        pub friends: Vec<FriendPresence> => count(0, MAX_PRESENCE_BATCH),
    }
}

wire_struct! {
    pub struct RoomListEntry {
        pub room_id: u32,
        pub players: u8 => range(0, MAX_ROOM_PLAYERS),
        pub max_players: u8 => range(1, MAX_ROOM_PLAYERS),
        pub density: Density,
        pub night: bool,
    }
}

wire_struct! {
    pub struct RoomList {
        pub rooms: Vec<RoomListEntry> => count(0, MAX_ROOM_LIST),
    }
}

wire_struct! {
    pub struct RoomLeft {
        pub reason: RoomLeftReason,
    }
}

wire_union! {
    /// Lobby notifications. JSON tag: `kind`.
    #[serde(tag = "kind", rename_all = "snake_case")]
    pub enum LobbyEvent {
        PartyState(PartyState) = 0,
        PartyLeft(PartyLeft) = 1,
        PartyInvite(PartyInvite) = 2,
        Presence(Presence) = 3,
        RoomList(RoomList) = 4,
        RoomLeft(RoomLeft) = 5,
        /// Protocol 2 (never sent to version 1 sessions).
        RoomInvite(RoomInvite) = 6,
        /// Protocol 2 (never sent to version 1 sessions).
        CrewInvite(CrewInvite) = 7,
    }
}

wire_struct! {
    pub struct Member {
        pub player_id: u16,
        pub identity: Identity,
        /// Persistent crew tag shown on the nametag (empty = none).
        pub crew_tag: CrewTag,
        /// Scoring crew in this room (see `RoomCrew`).
        pub crew_slot: u8 => range(0, MAX_CREWS - 1),
        pub flags: MemberFlags,
    }
}

wire_struct! {
    /// A scoring crew in the room (private room: everyone; public room: a party).
    pub struct RoomCrew {
        pub crew_slot: u8 => range(0, MAX_CREWS - 1),
        /// Crew color palette index (nametags).
        pub color: u8,
        /// Session crew total: combined banked score this room session.
        pub session_total: u32,
    }
}

wire_struct! {
    /// Sent on join: members, crews, clock, settings.
    pub struct RoomSnapshot {
        pub room_id: u32,
        pub code: Code,
        pub settings: RoomSettings,
        /// Current room tick; the clock is given at this tick.
        pub tick: u32,
        pub clock: RoomClock,
        /// Your player id in this room.
        pub you: u16,
        pub members: Vec<Member> => count(1, MAX_ROOM_PLAYERS),
        pub crews: Vec<RoomCrew> => count(0, MAX_CREWS),
    }
}

wire_struct! {
    pub struct PlayerStateEntry {
        pub player_id: u16,
        pub state: PlayerState,
    }
}

wire_struct! {
    /// Every other room member's latest state, batched once per tick.
    pub struct PlayerStates {
        pub players: Vec<PlayerStateEntry> => count(1, MAX_ROOM_PLAYERS),
    }
}

wire_struct! {
    /// A car entering the client's area of interest. 23 bytes.
    pub struct TrafficSpawnEntry {
        pub car_id: u16,
        /// Index into the exported vehicle roster.
        pub vehicle: u8,
        /// Index into the biome color palette.
        pub color: u8,
        /// Index into the exported driver profiles.
        pub profile: u8,
        /// Current lane (0 = rightmost).
        pub lane: u8 => range(0, MAX_LANES - 1),
        pub s_mm: u32,
        pub d_cm: i16 => range(-MAX_ABS_D_CM, MAX_ABS_D_CM),
        pub speed_cms: u16 => range(0, MAX_SPEED_CMS),
        /// Lane-change state: phase, target lane, move-start tick, move duration
        /// (all zero when the phase is `none`).
        pub lc_phase: LaneChangePhase,
        pub lc_target_lane: u8 => range(0, MAX_LANES - 1),
        pub lc_move_start_tick: u32,
        pub lc_duration_ms: u16,
        pub flags: TrafficFlags,
    }
}

wire_struct! {
    pub struct TrafficSpawn {
        pub cars: Vec<TrafficSpawnEntry> => count(1, MAX_TRAFFIC_BATCH),
    }
}

wire_struct! {
    pub struct TrafficDespawn {
        pub car_ids: Vec<u16> => count(1, MAX_TRAFFIC_BATCH),
    }
}

wire_struct! {
    /// A telegraphed traffic decision, broadcast when it is made. 14 bytes.
    pub struct TrafficIntentEntry {
        pub car_id: u16,
        pub kind: IntentKind,
        /// Blinker / effect start.
        pub start_tick: u32,
        /// Lateral move start (lane changes; equals `start_tick` otherwise).
        pub move_start_tick: u32,
        /// Lane changes only; 0 otherwise.
        pub target_lane: u8 => range(0, MAX_LANES - 1),
        /// Move duration (lane change) or effect duration (hazard, horn, hard brake), ms.
        pub duration_ms: u16,
    }
}

wire_struct! {
    pub struct TrafficIntent {
        pub intents: Vec<TrafficIntentEntry> => count(1, MAX_INTENT_BATCH),
    }
}

wire_struct! {
    /// Authoritative state of one car at the batch tick. 10 bytes.
    pub struct CorrectionEntry {
        pub car_id: u16,
        pub s_mm: u32,
        pub d_cm: i16 => range(-MAX_ABS_D_CM, MAX_ABS_D_CM),
        pub speed_cms: u16 => range(0, MAX_SPEED_CMS),
    }
}

wire_struct! {
    /// Corrections for one server tick (the tick is shared by the batch).
    pub struct TrafficCorrection {
        pub tick: u32,
        pub cars: Vec<CorrectionEntry> => count(1, MAX_TRAFFIC_BATCH),
    }
}

wire_struct! {
    /// Official score, at least once a second and at every banking moment.
    pub struct ScoreSync {
        pub tick: u32,
        /// Run counter for this player in this room (wrapping).
        pub run_seq: u16,
        pub banked: u32,
        pub chain: u32,
        /// Multiplier ×1e-3 (1.0× = 1000).
        pub multiplier_milli: u32,
        pub lives: u8,
        /// Crewmates within proximity range (HUD crew indicator).
        pub crew_in_range: u8 => range(0, MAX_ROOM_PLAYERS),
        pub flags: ScoreFlags,
    }
}

wire_struct! {
    /// Server-side score events: trains, sector bonuses, claim rejections.
    pub struct ScoreEvent {
        pub tick: u32,
        /// Who earned it (crews see each other's trains).
        pub player_id: u16,
        pub kind: ScoreEventKind,
        pub points: u32,
        pub multiplier_gain_milli: u32,
        /// Train link count (TRAIN ×n); 0 otherwise.
        pub link: u8,
        /// Sector index for sector bonuses; 0 otherwise.
        pub sector: u8,
        /// Car id (train) or claim id (claim_rejected); 0 otherwise.
        pub ref_id: u16,
    }
}

wire_struct! {
    /// A finished run (results toast, stats).
    pub struct RunResult {
        pub player_id: u16,
        pub run_seq: u16,
        pub end_reason: RunEndReason,
        pub flags: RunResultFlags,
        pub score: u32,
        pub duration_ms: u32,
        pub distance_m: u32,
        pub passes: u16,
        pub close_passes: u16,
        pub cuts: u16,
        pub threads: u16,
        pub trains: u16,
        pub max_multiplier_milli: u32,
    }
}

wire_struct! {
    pub struct MemberLeft {
        pub player_id: u16,
        pub reason: LeaveReason,
    }
}

wire_struct! {
    pub struct SettingsChanged {
        pub tick: u32,
        pub settings: RoomSettings,
        pub clock: RoomClock,
    }
}

wire_struct! {
    pub struct MemberConnection {
        pub player_id: u16,
        pub connected: bool,
    }
}

wire_union! {
    /// Room membership and settings changes. JSON tag: `kind`.
    #[serde(tag = "kind", rename_all = "snake_case")]
    pub enum RoomEvent {
        Join(Member) = 0,
        Leave(MemberLeft) = 1,
        HostChange(PlayerRef) = 2,
        Kick(PlayerRef) = 3,
        Settings(SettingsChanged) = 4,
        /// A crew was added or its session total changed.
        Crew(RoomCrew) = 5,
        /// A member disconnected (seat held) or reconnected.
        Connection(MemberConnection) = 6,
    }
}

wire_struct! {
    /// A quick-chat item relayed to the room.
    pub struct QuickChatRelay {
        pub player_id: u16,
        pub item: ChatItem,
    }
}

wire_struct! {
    pub struct ServerNotice {
        pub kind: NoticeKind,
        /// Seconds until the event (restart, maintenance); 0 for info.
        pub seconds: u16,
        pub text: Text,
    }
}

wire_union! {
    /// Every server → client message. JSON tag: `type`.
    #[serde(tag = "type", rename_all = "snake_case")]
    pub enum ServerMsg {
        Welcome(Welcome) = type_id::WELCOME,
        Pong(Pong) = type_id::PONG,
        Error(ErrorMsg) = type_id::ERROR,
        LobbyEvent(LobbyEvent) = type_id::LOBBY_EVENT,
        RoomSnapshot(RoomSnapshot) = type_id::ROOM_SNAPSHOT,
        PlayerStates(PlayerStates) = type_id::PLAYER_STATES,
        TrafficSpawn(TrafficSpawn) = type_id::TRAFFIC_SPAWN,
        TrafficDespawn(TrafficDespawn) = type_id::TRAFFIC_DESPAWN,
        TrafficIntent(TrafficIntent) = type_id::TRAFFIC_INTENT,
        TrafficCorrection(TrafficCorrection) = type_id::TRAFFIC_CORRECTION,
        ScoreSync(ScoreSync) = type_id::SCORE_SYNC,
        ScoreEvent(ScoreEvent) = type_id::SCORE_EVENT,
        RunResult(RunResult) = type_id::RUN_RESULT,
        RoomEvent(RoomEvent) = type_id::ROOM_EVENT,
        QuickChat(QuickChatRelay) = type_id::QUICK_CHAT_RELAY,
        ServerNotice(ServerNotice) = type_id::SERVER_NOTICE,
    }
}
