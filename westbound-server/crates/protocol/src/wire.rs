//! Wire primitives (multiplayer handoff → Networking protocol → Encoding): the bounds-checked
//! `Reader`, the `Wire` trait every field type implements, and the declarative macros that
//! implement it for structs, value enums, bit flags, tagged unions and bounded strings.
//!
//! All integers are little-endian. Nothing here panics on malformed input: every read checks
//! the remaining length first and returns `DecodeError::Truncated` instead.
#![deny(
    clippy::indexing_slicing,
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic
)]

use crate::error::{DecodeError, ValidationError};
pub use bytes::{Buf, BufMut};

/// Bounds-checked little-endian reader over one message payload.
#[derive(Debug)]
pub struct Reader<'a> {
    buf: &'a [u8],
}

impl<'a> Reader<'a> {
    pub fn new(buf: &'a [u8]) -> Self {
        Self { buf }
    }

    /// Bytes left to read.
    pub fn remaining(&self) -> usize {
        self.buf.len()
    }

    fn need(&self, n: usize) -> Result<(), DecodeError> {
        if self.buf.len() < n {
            Err(DecodeError::Truncated {
                needed: n,
                remaining: self.buf.len(),
            })
        } else {
            Ok(())
        }
    }

    pub fn u8(&mut self) -> Result<u8, DecodeError> {
        self.need(1)?;
        Ok(self.buf.get_u8())
    }

    pub fn u16(&mut self) -> Result<u16, DecodeError> {
        self.need(2)?;
        Ok(self.buf.get_u16_le())
    }

    pub fn u32(&mut self) -> Result<u32, DecodeError> {
        self.need(4)?;
        Ok(self.buf.get_u32_le())
    }

    pub fn u64(&mut self) -> Result<u64, DecodeError> {
        self.need(8)?;
        Ok(self.buf.get_u64_le())
    }

    pub fn i16(&mut self) -> Result<i16, DecodeError> {
        self.need(2)?;
        Ok(self.buf.get_i16_le())
    }

    /// Borrows the next `n` bytes.
    pub fn bytes(&mut self, n: usize) -> Result<&'a [u8], DecodeError> {
        self.need(n)?;
        let (head, tail) = self.buf.split_at(n);
        self.buf = tail;
        Ok(head)
    }
}

/// A type with a fixed binary layout. `write` assumes `validate()` passed (the frame writer
/// always validates first); `read` parses structure only and the message-level decoder runs
/// `validate()` afterwards, so range rules live in exactly one place.
pub trait Wire: Sized {
    /// Encoded size in bytes.
    fn wire_len(&self) -> usize;
    /// Appends the encoding.
    fn write<B: BufMut>(&self, w: &mut B);
    /// Parses one value.
    fn read(r: &mut Reader<'_>) -> Result<Self, DecodeError>;
    /// Range, count, length and character rules.
    fn validate(&self) -> Result<(), ValidationError> {
        Ok(())
    }
}

macro_rules! wire_int {
    ($t:ty, $len:expr, $put:ident, $get:ident) => {
        impl Wire for $t {
            #[inline]
            fn wire_len(&self) -> usize {
                $len
            }
            #[inline]
            fn write<B: BufMut>(&self, w: &mut B) {
                w.$put(*self);
            }
            #[inline]
            fn read(r: &mut Reader<'_>) -> Result<Self, DecodeError> {
                r.$get()
            }
        }
    };
}

wire_int!(u8, 1, put_u8, u8);
wire_int!(u16, 2, put_u16_le, u16);
wire_int!(u32, 4, put_u32_le, u32);
wire_int!(i16, 2, put_i16_le, i16);

/// Booleans are one byte, exactly 0 or 1; anything else is rejected.
impl Wire for bool {
    fn wire_len(&self) -> usize {
        1
    }
    fn write<B: BufMut>(&self, w: &mut B) {
        w.put_u8(u8::from(*self));
    }
    fn read(r: &mut Reader<'_>) -> Result<Self, DecodeError> {
        match r.u8()? {
            0 => Ok(false),
            1 => Ok(true),
            value => Err(DecodeError::InvalidBool {
                field: "bool",
                value,
            }),
        }
    }
}

/// Lists: a u8 item count followed by the items. Per-field caps are checked by `validate()`
/// (the `count(min, max)` field rule); the u8 count bounds any list at 255 regardless.
impl<T: Wire> Wire for Vec<T> {
    fn wire_len(&self) -> usize {
        1 + self.iter().map(Wire::wire_len).sum::<usize>()
    }
    fn write<B: BufMut>(&self, w: &mut B) {
        // validate() guarantees len <= 255.
        w.put_u8(u8::try_from(self.len()).unwrap_or(u8::MAX));
        for item in self {
            item.write(w);
        }
    }
    fn read(r: &mut Reader<'_>) -> Result<Self, DecodeError> {
        let count = usize::from(r.u8()?);
        let mut items = Vec::with_capacity(count.min(r.remaining()));
        for _ in 0..count {
            items.push(T::read(r)?);
        }
        Ok(items)
    }
    fn validate(&self) -> Result<(), ValidationError> {
        if self.len() > usize::from(u8::MAX) {
            return Err(ValidationError::BadCount {
                field: "list",
                count: self.len(),
                min: 0,
                max: usize::from(u8::MAX),
            });
        }
        self.iter().try_for_each(Wire::validate)
    }
}

/// Element type of a list field (used by the property-test strategies).
pub trait ListItem {
    type Item;
}

impl<T> ListItem for Vec<T> {
    type Item = T;
}

/// Field rules referenced from `wire_struct!` as `=> range(lo, hi)` / `=> count(lo, hi)`.
pub mod check {
    use crate::error::ValidationError;

    /// Inclusive integer range.
    pub fn range<T: Copy + Into<i64>>(
        field: &'static str,
        value: &T,
        min: i64,
        max: i64,
    ) -> Result<(), ValidationError> {
        let value: i64 = (*value).into();
        if value < min || value > max {
            Err(ValidationError::OutOfRange {
                field,
                value,
                min,
                max,
            })
        } else {
            Ok(())
        }
    }

    /// Inclusive list-length range.
    #[allow(clippy::ptr_arg)]
    pub fn count<T>(
        field: &'static str,
        list: &Vec<T>,
        min: usize,
        max: usize,
    ) -> Result<(), ValidationError> {
        if list.len() < min || list.len() > max {
            Err(ValidationError::BadCount {
                field,
                count: list.len(),
                min,
                max,
            })
        } else {
            Ok(())
        }
    }
}

/// Rules for a length-prefixed UTF-8 string field.
#[derive(Debug, Clone, Copy)]
pub struct StrRules {
    /// Field name used in errors.
    pub field: &'static str,
    /// `true`: u16 byte-length prefix; `false`: u8 byte-length prefix.
    pub wide_len: bool,
    pub max_bytes: usize,
    pub min_chars: usize,
    pub max_chars: usize,
    /// Per-character filter.
    pub allowed: fn(char) -> bool,
}

impl StrRules {
    pub fn read(&self, r: &mut Reader<'_>) -> Result<String, DecodeError> {
        let len = if self.wide_len {
            usize::from(r.u16()?)
        } else {
            usize::from(r.u8()?)
        };
        let raw = r.bytes(len)?;
        let text =
            std::str::from_utf8(raw).map_err(|_| DecodeError::InvalidUtf8 { field: self.field })?;
        Ok(text.to_owned())
    }

    pub fn write<B: BufMut>(&self, s: &str, w: &mut B) {
        // validate() guarantees the length fits the prefix.
        if self.wide_len {
            w.put_u16_le(u16::try_from(s.len()).unwrap_or(u16::MAX));
        } else {
            w.put_u8(u8::try_from(s.len()).unwrap_or(u8::MAX));
        }
        w.put_slice(s.as_bytes());
    }

    pub fn wire_len(&self, s: &str) -> usize {
        (if self.wide_len { 2 } else { 1 }) + s.len()
    }

    pub fn validate(&self, s: &str) -> Result<(), ValidationError> {
        let prefix_max = if self.wide_len {
            usize::from(u16::MAX)
        } else {
            usize::from(u8::MAX)
        };
        let max_bytes = self.max_bytes.min(prefix_max);
        if s.len() > max_bytes {
            return Err(ValidationError::StringTooLong {
                field: self.field,
                len: s.len(),
                max: max_bytes,
            });
        }
        let count = s.chars().count();
        if count < self.min_chars || count > self.max_chars {
            return Err(ValidationError::BadCharCount {
                field: self.field,
                count,
                min: self.min_chars,
                max: self.max_chars,
            });
        }
        if !s.chars().all(self.allowed) {
            return Err(ValidationError::BadChar { field: self.field });
        }
        Ok(())
    }
}

/// Property-test strategy for one struct field: `any::<T>()` unless the field has a rule.
#[allow(unused_macros)]
macro_rules! field_strategy {
    ($ty:ty) => {
        ::proptest::arbitrary::any::<$ty>()
    };
    ($ty:ty, range($lo:expr, $hi:expr)) => {
        (($lo) as $ty)..=(($hi) as $ty)
    };
    ($ty:ty, count($lo:expr, $hi:expr)) => {
        ::proptest::collection::vec(
            ::proptest::arbitrary::any::<<$ty as $crate::wire::ListItem>::Item>(),
            (($lo) as usize)..=(($hi) as usize),
        )
    };
}

/// A struct whose encoding is its fields in declaration order. Optional per-field rules:
/// `=> range(lo, hi)` (inclusive integer range) and `=> count(lo, hi)` (list length).
macro_rules! wire_struct {
    (
        $(#[$meta:meta])*
        pub struct $name:ident {
            $(
                $(#[$fmeta:meta])*
                pub $field:ident : $ty:ty $( => $check:ident ( $($arg:expr),* $(,)? ) )?
            ),* $(,)?
        }
    ) => {
        #[derive(Debug, Clone, PartialEq, Eq, Default, ::serde::Serialize, ::serde::Deserialize)]
        $(#[$meta])*
        pub struct $name {
            $( $(#[$fmeta])* pub $field: $ty, )*
        }

        impl $crate::wire::Wire for $name {
            #[inline]
            #[allow(unused_variables)]
            fn wire_len(&self) -> usize {
                0 $( + $crate::wire::Wire::wire_len(&self.$field) )*
            }
            #[inline]
            #[allow(unused_variables)]
            fn write<B: $crate::wire::BufMut>(&self, w: &mut B) {
                $( $crate::wire::Wire::write(&self.$field, w); )*
            }
            #[allow(unused_variables)]
            fn read(r: &mut $crate::wire::Reader<'_>) -> Result<Self, $crate::error::DecodeError> {
                Ok(Self { $( $field: $crate::wire::Wire::read(r)?, )* })
            }
            #[allow(clippy::unnecessary_cast, clippy::cast_lossless)]
            fn validate(&self) -> Result<(), $crate::error::ValidationError> {
                $(
                    $crate::wire::Wire::validate(&self.$field)?;
                    $(
                        $crate::wire::check::$check(
                            concat!(stringify!($name), ".", stringify!($field)),
                            &self.$field
                            $(, ($arg) as _)*
                        )?;
                    )?
                )*
                Ok(())
            }
        }

        #[cfg(test)]
        impl ::proptest::arbitrary::Arbitrary for $name {
            type Parameters = ();
            type Strategy = ::proptest::strategy::BoxedStrategy<Self>;
            #[allow(clippy::unnecessary_cast)]
            fn arbitrary_with(_: ()) -> Self::Strategy {
                use ::proptest::strategy::Strategy;
                let s = ::proptest::strategy::Just(Self::default()).boxed();
                $(
                    let s = (s, field_strategy!($ty $(, $check($($arg),*))?))
                        .prop_map(|(mut x, v)| { x.$field = v; x })
                        .boxed();
                )*
                s
            }
        }
    };
}

/// A u8 enum. JSON uses the snake_case variant name; the wire uses the discriminant.
/// Unknown discriminants are rejected with `DecodeError::InvalidEnum`.
macro_rules! wire_enum {
    (
        $(#[$meta:meta])*
        pub enum $name:ident {
            $( $(#[$vmeta:meta])* $variant:ident = $val:literal ),+ $(,)?
        }
    ) => {
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, ::serde::Serialize, ::serde::Deserialize)]
        $(#[$meta])*
        #[serde(rename_all = "snake_case")]
        #[repr(u8)]
        pub enum $name {
            $( $(#[$vmeta])* $variant = $val, )+
        }

        impl $name {
            /// Every variant in wire order.
            pub const ALL: &'static [Self] = &[ $( Self::$variant ),+ ];

            pub const fn to_u8(self) -> u8 {
                self as u8
            }

            pub fn from_u8(v: u8) -> Option<Self> {
                match v {
                    $( $val => Some(Self::$variant), )+
                    _ => None,
                }
            }
        }

        impl Default for $name {
            fn default() -> Self {
                wire_enum!(@first $($variant),+)
            }
        }

        impl $crate::wire::Wire for $name {
            #[inline]
            fn wire_len(&self) -> usize {
                1
            }
            #[inline]
            fn write<B: $crate::wire::BufMut>(&self, w: &mut B) {
                w.put_u8(self.to_u8());
            }
            fn read(r: &mut $crate::wire::Reader<'_>) -> Result<Self, $crate::error::DecodeError> {
                let v = r.u8()?;
                Self::from_u8(v).ok_or($crate::error::DecodeError::InvalidEnum {
                    field: stringify!($name),
                    value: v,
                })
            }
        }

        #[cfg(test)]
        impl ::proptest::arbitrary::Arbitrary for $name {
            type Parameters = ();
            type Strategy = ::proptest::sample::Select<Self>;
            fn arbitrary_with(_: ()) -> Self::Strategy {
                ::proptest::sample::select(Self::ALL)
            }
        }
    };
    (@first $first:ident $(, $rest:ident)*) => { Self::$first };
}

/// Up to 8 booleans packed into one byte (bit 0 first). JSON: an object of booleans.
/// Reserved (unused) bits must be zero.
macro_rules! wire_flags {
    (
        $(#[$meta:meta])*
        pub struct $name:ident {
            $( $(#[$fmeta:meta])* pub $flag:ident = $bit:literal ),+ $(,)?
        }
    ) => {
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Default, ::serde::Serialize, ::serde::Deserialize)]
        $(#[$meta])*
        pub struct $name {
            $( $(#[$fmeta])* pub $flag: bool, )+
        }

        impl $name {
            /// Bits in use.
            pub const MASK: u8 = 0 $( | (1u8 << $bit) )+;

            pub fn bits(&self) -> u8 {
                0 $( | (u8::from(self.$flag) << $bit) )+
            }

            /// `None` when a reserved bit is set.
            pub fn from_bits(bits: u8) -> Option<Self> {
                if bits & !Self::MASK != 0 {
                    return None;
                }
                Some(Self { $( $flag: bits & (1u8 << $bit) != 0, )+ })
            }
        }

        impl $crate::wire::Wire for $name {
            #[inline]
            fn wire_len(&self) -> usize {
                1
            }
            #[inline]
            fn write<B: $crate::wire::BufMut>(&self, w: &mut B) {
                w.put_u8(self.bits());
            }
            fn read(r: &mut $crate::wire::Reader<'_>) -> Result<Self, $crate::error::DecodeError> {
                let v = r.u8()?;
                Self::from_bits(v).ok_or($crate::error::DecodeError::ReservedBits {
                    field: stringify!($name),
                    value: v,
                })
            }
        }

        #[cfg(test)]
        impl ::proptest::arbitrary::Arbitrary for $name {
            type Parameters = ();
            type Strategy = ::proptest::strategy::BoxedStrategy<Self>;
            fn arbitrary_with(_: ()) -> Self::Strategy {
                use ::proptest::strategy::Strategy;
                ::proptest::arbitrary::any::<u8>()
                    .prop_map(|b| Self::from_bits(b & Self::MASK).unwrap_or_default())
                    .boxed()
            }
        }
    };
}

/// A tagged union: a u8 tag followed by the variant's body. Every variant wraps one type
/// (use `Empty` for variants without fields). The serde tag name is given by the caller's
/// `#[serde(tag = "...")]` attribute. `tag`/`read_body`/`write_body` are also used by the
/// top-level `ClientMsg`/`ServerMsg`, where the tag is the frame's message type byte.
macro_rules! wire_union {
    (
        $(#[$meta:meta])*
        pub enum $name:ident {
            $( $(#[$vmeta:meta])* $variant:ident($inner:ty) = $tag:expr ),+ $(,)?
        }
    ) => {
        #[derive(Debug, Clone, PartialEq, Eq, ::serde::Serialize, ::serde::Deserialize)]
        $(#[$meta])*
        pub enum $name {
            $( $(#[$vmeta])* $variant($inner), )+
        }

        impl $name {
            /// Every tag in declaration order.
            pub const TAGS: &'static [u8] = &[ $( $tag ),+ ];

            /// The variant's wire tag.
            pub fn tag(&self) -> u8 {
                match self {
                    $( Self::$variant(_) => $tag, )+
                }
            }

            /// Encoded size of the body (without the tag).
            pub fn body_len(&self) -> usize {
                match self {
                    $( Self::$variant(x) => $crate::wire::Wire::wire_len(x), )+
                }
            }

            /// Writes the body (without the tag).
            pub fn write_body<B: $crate::wire::BufMut>(&self, w: &mut B) {
                match self {
                    $( Self::$variant(x) => $crate::wire::Wire::write(x, w), )+
                }
            }

            /// Parses the body for `tag`; `None` when the tag is unknown.
            pub fn read_body(
                tag: u8,
                r: &mut $crate::wire::Reader<'_>,
            ) -> Option<Result<Self, $crate::error::DecodeError>> {
                $(
                    if tag == $tag {
                        return Some(<$inner as $crate::wire::Wire>::read(r).map(Self::$variant));
                    }
                )+
                None
            }

            pub fn validate_body(&self) -> Result<(), $crate::error::ValidationError> {
                match self {
                    $( Self::$variant(x) => $crate::wire::Wire::validate(x), )+
                }
            }
        }

        impl Default for $name {
            fn default() -> Self {
                wire_union!(@first $($variant($inner)),+)
            }
        }

        impl $crate::wire::Wire for $name {
            fn wire_len(&self) -> usize {
                1 + self.body_len()
            }
            fn write<B: $crate::wire::BufMut>(&self, w: &mut B) {
                w.put_u8(self.tag());
                self.write_body(w);
            }
            fn read(r: &mut $crate::wire::Reader<'_>) -> Result<Self, $crate::error::DecodeError> {
                let tag = r.u8()?;
                Self::read_body(tag, r).unwrap_or(Err($crate::error::DecodeError::InvalidEnum {
                    field: stringify!($name),
                    value: tag,
                }))
            }
            fn validate(&self) -> Result<(), $crate::error::ValidationError> {
                self.validate_body()
            }
        }

        #[cfg(test)]
        impl ::proptest::arbitrary::Arbitrary for $name {
            type Parameters = ();
            type Strategy = ::proptest::strategy::BoxedStrategy<Self>;
            fn arbitrary_with(_: ()) -> Self::Strategy {
                use ::proptest::strategy::Strategy;
                ::proptest::strategy::Union::new(vec![
                    $( ::proptest::arbitrary::any::<$inner>().prop_map(Self::$variant).boxed() ),+
                ])
                .boxed()
            }
        }
    };
    (@first $first:ident($inner:ty) $(, $rest:ident($rinner:ty))*) => {
        Self::$first(<$inner>::default())
    };
}

/// A bounded, length-prefixed UTF-8 string newtype. JSON: a plain string.
macro_rules! wire_str {
    (
        $(#[$meta:meta])*
        pub struct $name:ident;
        rules = $rules:expr;
        strategy = $re:literal;
    ) => {
        #[derive(Debug, Clone, PartialEq, Eq, Hash, Default, ::serde::Serialize, ::serde::Deserialize)]
        $(#[$meta])*
        #[serde(transparent)]
        pub struct $name(pub String);

        impl $name {
            pub const RULES: $crate::wire::StrRules = $rules;

            /// Builds a validated value.
            pub fn new(s: impl Into<String>) -> Result<Self, $crate::error::ValidationError> {
                let v = Self(s.into());
                Self::RULES.validate(&v.0)?;
                Ok(v)
            }

            pub fn as_str(&self) -> &str {
                &self.0
            }
        }

        impl $crate::wire::Wire for $name {
            fn wire_len(&self) -> usize {
                Self::RULES.wire_len(&self.0)
            }
            fn write<B: $crate::wire::BufMut>(&self, w: &mut B) {
                Self::RULES.write(&self.0, w);
            }
            fn read(r: &mut $crate::wire::Reader<'_>) -> Result<Self, $crate::error::DecodeError> {
                Self::RULES.read(r).map(Self)
            }
            fn validate(&self) -> Result<(), $crate::error::ValidationError> {
                Self::RULES.validate(&self.0)
            }
        }

        #[cfg(test)]
        impl ::proptest::arbitrary::Arbitrary for $name {
            type Parameters = ();
            type Strategy = ::proptest::strategy::BoxedStrategy<Self>;
            fn arbitrary_with(_: ()) -> Self::Strategy {
                use ::proptest::strategy::Strategy;
                ::proptest::string::string_regex($re)
                    .unwrap()
                    .prop_map(Self)
                    .boxed()
            }
        }
    };
}
