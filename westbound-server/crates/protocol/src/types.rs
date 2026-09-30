//! Shared field types: account ids, the map hash, bounded strings, value enums and flag sets
//! (multiplayer handoff → Networking protocol, Players, Rooms, parties and matchmaking).

use crate::error::{DecodeError, ValidationError};
use crate::wire::{BufMut, Reader, StrRules, Wire};
use serde::{Deserialize, Deserializer, Serialize, Serializer};

// ---------------------------------------------------------------------------------------------
// Account id
// ---------------------------------------------------------------------------------------------

/// Largest valid account id: `i64::MAX`, so ids fit SQLite rowids and GDScript's signed int.
pub const MAX_ACCOUNT_ID: u64 = i64::MAX as u64;

/// A persistent account id (u64 on the wire, at most `i64::MAX`). JSON: a decimal *string*,
/// because JSON numbers above 2^53 lose precision in GDScript's parser.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Default)]
pub struct AccountId(pub u64);

impl Serialize for AccountId {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.0.to_string())
    }
}

impl<'de> Deserialize<'de> for AccountId {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        s.parse::<u64>()
            .map(AccountId)
            .map_err(serde::de::Error::custom)
    }
}

impl Wire for AccountId {
    fn wire_len(&self) -> usize {
        8
    }
    fn write<B: BufMut>(&self, w: &mut B) {
        w.put_u64_le(self.0);
    }
    fn read(r: &mut Reader<'_>) -> Result<Self, DecodeError> {
        r.u64().map(AccountId)
    }
    fn validate(&self) -> Result<(), ValidationError> {
        if self.0 > MAX_ACCOUNT_ID {
            // Reported with the clamped value so it fits the i64 error field.
            return Err(ValidationError::OutOfRange {
                field: "account_id",
                value: i64::MAX,
                min: 0,
                max: i64::MAX,
            });
        }
        Ok(())
    }
}

#[cfg(test)]
impl proptest::arbitrary::Arbitrary for AccountId {
    type Parameters = ();
    type Strategy = proptest::strategy::Map<std::ops::RangeInclusive<u64>, fn(u64) -> Self>;
    fn arbitrary_with(_: ()) -> Self::Strategy {
        use proptest::strategy::Strategy;
        (0..=MAX_ACCOUNT_ID).prop_map(AccountId)
    }
}

// ---------------------------------------------------------------------------------------------
// Map hash
// ---------------------------------------------------------------------------------------------

/// Length of the map content hash (SHA-256 of the road-space file).
pub const MAP_HASH_LEN: usize = 32;

/// Content hash of the loop's road-space file: 32 raw bytes on the wire; JSON: 64 lowercase
/// hex characters.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct MapHash(pub [u8; MAP_HASH_LEN]);

impl Serialize for MapHash {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&hex::encode(self.0))
    }
}

impl<'de> Deserialize<'de> for MapHash {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        let mut out = [0u8; MAP_HASH_LEN];
        hex::decode_to_slice(&s, &mut out).map_err(serde::de::Error::custom)?;
        Ok(MapHash(out))
    }
}

impl Wire for MapHash {
    fn wire_len(&self) -> usize {
        MAP_HASH_LEN
    }
    fn write<B: BufMut>(&self, w: &mut B) {
        w.put_slice(&self.0);
    }
    fn read(r: &mut Reader<'_>) -> Result<Self, DecodeError> {
        let raw = r.bytes(MAP_HASH_LEN)?;
        let mut out = [0u8; MAP_HASH_LEN];
        out.copy_from_slice(raw);
        Ok(MapHash(out))
    }
}

#[cfg(test)]
impl proptest::arbitrary::Arbitrary for MapHash {
    type Parameters = ();
    type Strategy = proptest::strategy::BoxedStrategy<Self>;
    fn arbitrary_with(_: ()) -> Self::Strategy {
        use proptest::strategy::Strategy;
        proptest::arbitrary::any::<[u8; MAP_HASH_LEN]>()
            .prop_map(MapHash)
            .boxed()
    }
}

// ---------------------------------------------------------------------------------------------
// Bounded strings
// ---------------------------------------------------------------------------------------------

/// Room and party codes: 6 characters from this alphabet (no 0/O, 1/I/L).
pub const CODE_ALPHABET: &str = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
/// Characters in a room or party code.
pub const CODE_LEN: usize = 6;
/// Display names: 1–16 characters (the server enforces its 3-character minimum), at most 64 bytes.
pub const MAX_NAME_CHARS: usize = 16;
pub const MAX_NAME_BYTES: usize = 64;
/// Crew tags: 0–4 characters (empty = no crew), at most 16 bytes.
pub const MAX_CREW_TAG_CHARS: usize = 4;
pub const MAX_CREW_TAG_BYTES: usize = 16;
/// Access tokens (JWT): printable ASCII, at most 2048 bytes, u16 length prefix.
pub const MAX_TOKEN_BYTES: usize = 2048;
/// Free text from the server (error details, notices): at most 255 bytes.
pub const MAX_TEXT_BYTES: usize = 255;

/// Name characters: no control characters and no invisible/bidi formatting characters.
pub fn name_char(c: char) -> bool {
    !c.is_control()
        && !matches!(c,
            '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}' | '\u{FEFF}')
}

/// Code characters: `CODE_ALPHABET` only.
pub fn code_char(c: char) -> bool {
    CODE_ALPHABET.contains(c)
}

/// Token characters: printable ASCII without spaces.
pub fn token_char(c: char) -> bool {
    c.is_ascii_graphic()
}

/// Server text characters: anything except control characters other than newline.
pub fn text_char(c: char) -> bool {
    c == '\n' || !c.is_control()
}

wire_str! {
    /// A display name without its `#1234` tag (u8 length prefix).
    pub struct DisplayName;
    rules = StrRules {
        field: "display_name",
        wide_len: false,
        max_bytes: MAX_NAME_BYTES,
        min_chars: 1,
        max_chars: MAX_NAME_CHARS,
        allowed: name_char,
    };
    strategy = "[^\\p{C}]{1,16}";
}

wire_str! {
    /// A persistent crew tag, 0–4 characters (u8 length prefix). Empty means no crew.
    pub struct CrewTag;
    rules = StrRules {
        field: "crew_tag",
        wide_len: false,
        max_bytes: MAX_CREW_TAG_BYTES,
        min_chars: 0,
        max_chars: MAX_CREW_TAG_CHARS,
        allowed: name_char,
    };
    strategy = "[^\\p{C}]{0,4}";
}

wire_str! {
    /// A room or party code: exactly 6 characters from `CODE_ALPHABET` (u8 length prefix).
    pub struct Code;
    rules = StrRules {
        field: "code",
        wide_len: false,
        max_bytes: CODE_LEN,
        min_chars: CODE_LEN,
        max_chars: CODE_LEN,
        allowed: code_char,
    };
    strategy = "[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}";
}

wire_str! {
    /// The access token (JWT) sent in `Hello` (u16 length prefix).
    pub struct AccessToken;
    rules = StrRules {
        field: "access_token",
        wide_len: true,
        max_bytes: MAX_TOKEN_BYTES,
        min_chars: 0,
        max_chars: MAX_TOKEN_BYTES,
        allowed: token_char,
    };
    strategy = "[A-Za-z0-9._-]{0,64}";
}

wire_str! {
    /// Human-readable server text (u8 length prefix, at most 255 bytes).
    pub struct Text;
    rules = StrRules {
        field: "text",
        wide_len: false,
        max_bytes: MAX_TEXT_BYTES,
        min_chars: 0,
        max_chars: MAX_TEXT_BYTES,
        allowed: text_char,
    };
    strategy = "[^\\p{C}]{0,40}";
}

// ---------------------------------------------------------------------------------------------
// Empty body
// ---------------------------------------------------------------------------------------------

wire_struct! {
    /// A union variant without fields (zero payload bytes).
    pub struct Empty {}
}

// ---------------------------------------------------------------------------------------------
// Value enums (u8 on the wire, snake_case strings in JSON)
// ---------------------------------------------------------------------------------------------

wire_enum! {
    /// A player's run state in `PlayerState`.
    pub enum RunState {
        /// In the room but not driving (menu, results toast, waiting to spawn).
        NotRunning = 0,
        /// Spawn or rejoin protection: no traffic hits, minimum-speed rule paused.
        Protected = 1,
        Driving = 2,
        /// Second hit; the run is over and the crash plays out.
        Crashed = 3,
    }
}

wire_enum! {
    /// Lane-change phase of a traffic car at spawn time.
    pub enum LaneChangePhase {
        None = 0,
        /// Blinker on, not moving yet.
        Signaling = 1,
        /// Moving toward the target lane.
        Moving = 2,
    }
}

wire_enum! {
    /// A telegraphed traffic decision (`TrafficIntent`).
    pub enum IntentKind {
        LaneChange = 0,
        /// Cancels the car's pending lane change (hesitant drivers).
        Cancel = 1,
        Hazard = 2,
        Horn = 3,
        HardBrake = 4,
    }
}

wire_enum! {
    /// Scoring event claimed by a client.
    pub enum ClaimKind {
        Pass = 0,
        ClosePass = 1,
        Cut = 2,
        Thread = 3,
    }
}

wire_enum! {
    /// Which side of the player the traffic car was on.
    pub enum Side {
        None = 0,
        Left = 1,
        Right = 2,
    }
}

wire_enum! {
    /// What the player hit.
    pub enum HitTarget {
        Traffic = 0,
        Barrier = 1,
        Roadside = 2,
    }
}

wire_enum! {
    /// Client run lifecycle events.
    pub enum RunEventKind {
        Start = 0,
        End = 1,
        /// Teleport to the crew; forfeits the unbanked chain.
        Rejoin = 2,
    }
}

wire_enum! {
    /// Quick-chat preset phrases.
    pub enum Phrase {
        NiceThread = 0,
        FollowMe = 1,
        SlowDown = 2,
        Regroup = 3,
        Gg = 4,
        OneMoreLap = 5,
    }
}

wire_enum! {
    /// Room traffic density (vehicles per km per lane come from server config).
    pub enum Density {
        Light = 0,
        Normal = 1,
        Rush = 2,
    }
}

wire_enum! {
    /// Room time-of-day mode.
    pub enum TimeMode {
        /// The day/night cycle runs (UTC-derived in public rooms).
        Cycle = 0,
        /// The clock is frozen at `fixed_cycle_ms`.
        Fixed = 1,
        /// Permanent night.
        Night = 2,
    }
}

wire_enum! {
    pub enum Visibility {
        Private = 0,
        Public = 1,
    }
}

wire_enum! {
    /// A friend's presence.
    pub enum PresenceStatus {
        Offline = 0,
        Online = 1,
        InRoom = 2,
    }
}

wire_enum! {
    /// Why you are no longer in a party.
    pub enum PartyLeftReason {
        Left = 0,
        Kicked = 1,
        Disbanded = 2,
    }
}

wire_enum! {
    /// Why you are no longer in a room.
    pub enum RoomLeftReason {
        Left = 0,
        Kicked = 1,
        Closed = 2,
        /// Your seat hold expired after a disconnect.
        TimedOut = 3,
    }
}

wire_enum! {
    /// Why another member left the room.
    pub enum LeaveReason {
        Left = 0,
        /// Seat hold expired after a disconnect.
        TimedOut = 1,
    }
}

wire_enum! {
    /// `Error` codes. The first three are the "please update" family.
    pub enum ErrorCode {
        /// Client protocol or build too old: "please update".
        UpdateRequired = 0,
        /// Client protocol newer than the server: retry later.
        ServerOutdated = 1,
        /// Map hash differs from the server's: "please update".
        MapMismatch = 2,
        AuthFailed = 3,
        Banned = 4,
        /// A message other than `Hello` arrived first.
        HandshakeRequired = 5,
        /// Undecodable or invalid frame.
        Malformed = 6,
        RateLimited = 7,
        ServerFull = 8,
        RoomNotFound = 9,
        RoomFull = 10,
        PartyNotFound = 11,
        PartyFull = 12,
        NotHost = 13,
        NotPartyLeader = 14,
        NotInRoom = 15,
        AlreadyInRoom = 16,
        Blocked = 17,
        NotAllowed = 18,
        Internal = 19,
    }
}

wire_enum! {
    /// Server-side score events (crew bonuses, trains, sector bonuses, claim rejections).
    pub enum ScoreEventKind {
        Train = 0,
        SectorClean = 1,
        SectorPace = 2,
        SectorThreads = 3,
        SectorHeat = 4,
        /// A claim failed server verification (dev HUD); `ref_id` is the claim id.
        ClaimRejected = 5,
    }
}

wire_enum! {
    pub enum RunEndReason {
        Crashed = 0,
        Quit = 1,
        Disconnected = 2,
        RoomClosed = 3,
    }
}

wire_enum! {
    pub enum NoticeKind {
        Info = 0,
        /// Planned restart in `seconds`; clients reconnect automatically.
        Restart = 1,
        Maintenance = 2,
    }
}

// ---------------------------------------------------------------------------------------------
// Flag sets (one byte, JSON object of booleans)
// ---------------------------------------------------------------------------------------------

wire_flags! {
    /// `PlayerState.flags`.
    pub struct PlayerFlags {
        pub brake = 0,
        pub boost = 1,
        pub headlights = 2,
        /// Post-hit ghost period.
        pub ghost = 3,
    }
}

wire_flags! {
    /// Traffic car status at spawn.
    pub struct TrafficFlags {
        pub hazard = 0,
        pub braking = 1,
    }
}

wire_flags! {
    pub struct MemberFlags {
        pub host = 0,
        /// Disconnected; seat held.
        pub disconnected = 1,
    }
}

wire_flags! {
    pub struct ScoreFlags {
        /// This sync is a banking moment: the client eases its display to these values.
        pub banking = 0,
        /// Night ×2 is active.
        pub night = 1,
        /// The run is marked unverified (never reaches a leaderboard).
        pub unverified = 2,
    }
}

wire_flags! {
    pub struct RunResultFlags {
        pub verified = 0,
        pub leaderboard_eligible = 1,
    }
}
