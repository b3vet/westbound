//! Error types for decoding, validation, encoding and quantization (multiplayer handoff →
//! Rules for the server code, rule 3: every inbound message is validated for size and ranges).
//!
//! Every error has a stable snake_case `kind()` string. The golden vectors in `invalid.json`
//! name the expected kind so the GDScript codec can assert the same rejection.

use thiserror::Error;

/// A value that decoded structurally but breaks a range, count, length or character rule.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ValidationError {
    #[error("{field} = {value} is outside {min}..={max}")]
    OutOfRange {
        field: &'static str,
        value: i64,
        min: i64,
        max: i64,
    },
    #[error("{field} has {count} items; allowed {min}..={max}")]
    BadCount {
        field: &'static str,
        count: usize,
        min: usize,
        max: usize,
    },
    #[error("{field} is {len} bytes; max {max}")]
    StringTooLong {
        field: &'static str,
        len: usize,
        max: usize,
    },
    #[error("{field} has {count} characters; allowed {min}..={max}")]
    BadCharCount {
        field: &'static str,
        count: usize,
        min: usize,
        max: usize,
    },
    #[error("{field} contains a character that is not allowed")]
    BadChar { field: &'static str },
}

impl ValidationError {
    /// Stable snake_case name of the error, used by the golden vectors.
    pub fn kind(&self) -> &'static str {
        match self {
            Self::OutOfRange { .. } => "out_of_range",
            Self::BadCount { .. } => "bad_count",
            Self::StringTooLong { .. } => "string_too_long",
            Self::BadCharCount { .. } => "bad_char_count",
            Self::BadChar { .. } => "bad_char",
        }
    }
}

/// Why an inbound frame was rejected. The decoder never panics; every malformed input maps here.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum DecodeError {
    #[error("empty frame")]
    EmptyFrame,
    #[error("frame is {len} bytes; max {max}")]
    FrameTooLarge { len: usize, max: usize },
    #[error("frame holds more than {max} messages")]
    TooManyMessages { max: usize },
    #[error("truncated: needed {needed} bytes, {remaining} left")]
    Truncated { needed: usize, remaining: usize },
    #[error("unknown message type 0x{0:02x}")]
    UnknownType(u8),
    #[error("message type 0x{type_id:02x} left {extra} payload bytes unread")]
    TrailingBytes { type_id: u8, extra: usize },
    #[error("invalid {field} value {value}")]
    InvalidEnum { field: &'static str, value: u8 },
    #[error("invalid bool {value} in {field}")]
    InvalidBool { field: &'static str, value: u8 },
    #[error("reserved bits set in {field}: 0x{value:02x}")]
    ReservedBits { field: &'static str, value: u8 },
    #[error("invalid UTF-8 in {field}")]
    InvalidUtf8 { field: &'static str },
    #[error(transparent)]
    Invalid(#[from] ValidationError),
}

impl DecodeError {
    /// Stable snake_case name of the error, used by the golden vectors.
    pub fn kind(&self) -> &'static str {
        match self {
            Self::EmptyFrame => "empty_frame",
            Self::FrameTooLarge { .. } => "frame_too_large",
            Self::TooManyMessages { .. } => "too_many_messages",
            Self::Truncated { .. } => "truncated",
            Self::UnknownType(_) => "unknown_type",
            Self::TrailingBytes { .. } => "trailing_bytes",
            Self::InvalidEnum { .. } => "invalid_enum",
            Self::InvalidBool { .. } => "invalid_bool",
            Self::ReservedBits { .. } => "reserved_bits",
            Self::InvalidUtf8 { .. } => "invalid_utf8",
            Self::Invalid(v) => v.kind(),
        }
    }
}

/// Why a message could not be written.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum EncodeError {
    #[error(transparent)]
    Invalid(#[from] ValidationError),
    #[error("message payload is {len} bytes; max {max}")]
    PayloadTooLarge { len: usize, max: usize },
    #[error("frame full: {needed} bytes needed, {available} available")]
    FrameFull { needed: usize, available: usize },
    #[error("batch full ({max} items)")]
    BatchFull { max: usize },
    #[error("frame already holds {max} messages")]
    TooManyMessages { max: usize },
}

/// A physical value that cannot be quantized (see `quant`).
#[derive(Debug, Clone, Copy, PartialEq, Error)]
pub enum QuantError {
    #[error("{field} is not finite")]
    NotFinite { field: &'static str },
    #[error("{field} = {value} is outside the wire range")]
    OutOfRange { field: &'static str, value: f64 },
}
