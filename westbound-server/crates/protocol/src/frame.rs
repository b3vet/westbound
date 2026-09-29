//! Framing (multiplayer handoff → Networking protocol → Encoding; Rules for the server code 3–4):
//! a frame is one WebSocket binary message holding one or more messages, each
//! `[u8 type][u16 length LE][payload]`. Decoding is lazy, bounded and never panics;
//! `FrameBuilder` bundles a tick's messages into one reusable buffer, with streaming batch
//! writers so the server can emit per-car entries without building intermediate `Vec`s.
#![deny(
    clippy::indexing_slicing,
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic
)]

use std::marker::PhantomData;

use bytes::{BufMut, Bytes, BytesMut};

use crate::error::{DecodeError, EncodeError, ValidationError};
use crate::messages::{
    type_id, ClientMsg, CorrectionEntry, PlayerStateEntry, ServerMsg, TrafficIntentEntry,
    TrafficSpawnEntry, MAX_INTENT_BATCH, MAX_ROOM_PLAYERS, MAX_TRAFFIC_BATCH,
};
use crate::wire::{Reader, Wire};
use crate::{MAX_FRAME_LEN, MAX_MESSAGES_PER_FRAME, MSG_HEADER_LEN};

/// A top-level message set for one direction (`ClientMsg` or `ServerMsg`).
pub trait Message: Sized {
    /// The frame's type byte.
    fn type_id(&self) -> u8;
    /// Payload size (without the 3-byte header).
    fn payload_len(&self) -> usize;
    /// Writes the payload (without the header). Assumes `validate()` passed.
    fn write_payload<B: BufMut>(&self, w: &mut B);
    /// Parses and validates one payload. Unknown types, short or long payloads and range
    /// violations are errors.
    fn read_payload(type_id: u8, payload: &[u8]) -> Result<Self, DecodeError>;
    /// All range, count and string rules.
    fn validate(&self) -> Result<(), ValidationError>;
    /// Header + payload size.
    fn encoded_len(&self) -> usize {
        MSG_HEADER_LEN + self.payload_len()
    }
}

macro_rules! impl_message {
    ($t:ty) => {
        impl Message for $t {
            fn type_id(&self) -> u8 {
                self.tag()
            }
            fn payload_len(&self) -> usize {
                self.body_len()
            }
            fn write_payload<B: BufMut>(&self, w: &mut B) {
                self.write_body(w)
            }
            fn read_payload(type_id: u8, payload: &[u8]) -> Result<Self, DecodeError> {
                let mut r = Reader::new(payload);
                let msg =
                    Self::read_body(type_id, &mut r).ok_or(DecodeError::UnknownType(type_id))??;
                if r.remaining() != 0 {
                    return Err(DecodeError::TrailingBytes {
                        type_id,
                        extra: r.remaining(),
                    });
                }
                msg.validate_body()?;
                Ok(msg)
            }
            fn validate(&self) -> Result<(), ValidationError> {
                self.validate_body()
            }
        }
    };
}

impl_message!(ClientMsg);
impl_message!(ServerMsg);

/// Lazy frame decoder: yields each message in order and stops after the first error.
/// Checks up front: the frame is non-empty and at most `MAX_FRAME_LEN` bytes; then at most
/// `MAX_MESSAGES_PER_FRAME` messages.
#[derive(Debug)]
pub struct FrameReader<'a, M> {
    reader: Reader<'a>,
    frame_len: usize,
    count: usize,
    started: bool,
    done: bool,
    _msg: PhantomData<fn() -> M>,
}

impl<'a, M: Message> FrameReader<'a, M> {
    pub fn new(frame: &'a [u8]) -> Self {
        Self {
            reader: Reader::new(frame),
            frame_len: frame.len(),
            count: 0,
            started: false,
            done: false,
            _msg: PhantomData,
        }
    }

    fn fail(&mut self, e: DecodeError) -> Option<Result<M, DecodeError>> {
        self.done = true;
        Some(Err(e))
    }
}

impl<M: Message> Iterator for FrameReader<'_, M> {
    type Item = Result<M, DecodeError>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.done {
            return None;
        }
        if !self.started {
            self.started = true;
            if self.frame_len == 0 {
                return self.fail(DecodeError::EmptyFrame);
            }
            if self.frame_len > MAX_FRAME_LEN {
                return self.fail(DecodeError::FrameTooLarge {
                    len: self.frame_len,
                    max: MAX_FRAME_LEN,
                });
            }
        }
        if self.reader.remaining() == 0 {
            self.done = true;
            return None;
        }
        if self.count == MAX_MESSAGES_PER_FRAME {
            return self.fail(DecodeError::TooManyMessages {
                max: MAX_MESSAGES_PER_FRAME,
            });
        }
        let header = (|| {
            let ty = self.reader.u8()?;
            let len = self.reader.u16()?;
            let payload = self.reader.bytes(usize::from(len))?;
            Ok::<_, DecodeError>((ty, payload))
        })();
        let (ty, payload) = match header {
            Ok(h) => h,
            Err(e) => return self.fail(e),
        };
        self.count += 1;
        match M::read_payload(ty, payload) {
            Ok(m) => Some(Ok(m)),
            Err(e) => self.fail(e),
        }
    }
}

/// Iterates a frame's messages lazily.
pub fn read_frame<M: Message>(frame: &[u8]) -> FrameReader<'_, M> {
    FrameReader::new(frame)
}

/// Decodes a whole frame; any error rejects the whole frame.
pub fn decode_frame<M: Message>(frame: &[u8]) -> Result<Vec<M>, DecodeError> {
    read_frame(frame).collect()
}

/// Client frames, as the server reads them.
pub fn decode_client_frame(frame: &[u8]) -> Result<Vec<ClientMsg>, DecodeError> {
    decode_frame(frame)
}

/// Server frames, as a client reads them.
pub fn decode_server_frame(frame: &[u8]) -> Result<Vec<ServerMsg>, DecodeError> {
    decode_frame(frame)
}

/// Validates and appends one framed message. Returns the bytes written.
pub fn encode_message_into<M: Message, B: BufMut>(m: &M, w: &mut B) -> Result<usize, EncodeError> {
    m.validate()?;
    let len = m.payload_len();
    let len16 = u16::try_from(len).map_err(|_| EncodeError::PayloadTooLarge {
        len,
        max: usize::from(u16::MAX),
    })?;
    w.put_u8(m.type_id());
    w.put_u16_le(len16);
    m.write_payload(w);
    Ok(MSG_HEADER_LEN + len)
}

/// Encodes a frame from a slice of messages (convenience; the server uses `FrameBuilder`).
pub fn encode_frame<M: Message>(msgs: &[M]) -> Result<Bytes, EncodeError> {
    let mut fb = FrameBuilder::new();
    for m in msgs {
        fb.push(m)?;
    }
    Ok(fb.finish())
}

/// Builds one outbound frame per tick. The buffer is reused across ticks: `finish()` splits
/// off the frame and keeps the allocation for the next tick once the frame has been sent and
/// dropped. Every push validates, checks the frame limit (default `MAX_FRAME_LEN`) and the
/// message cap, and writes nothing on failure, so a caller can defer the rest to the next tick.
#[derive(Debug)]
pub struct FrameBuilder {
    buf: BytesMut,
    max_len: usize,
    messages: usize,
}

impl Default for FrameBuilder {
    fn default() -> Self {
        Self::new()
    }
}

impl FrameBuilder {
    /// A builder limited to `MAX_FRAME_LEN`.
    pub fn new() -> Self {
        Self::with_limit(MAX_FRAME_LEN)
    }

    /// A builder with a smaller byte limit (never above `MAX_FRAME_LEN`).
    pub fn with_limit(max_len: usize) -> Self {
        let max_len = max_len.min(MAX_FRAME_LEN);
        Self {
            buf: BytesMut::with_capacity(max_len),
            max_len,
            messages: 0,
        }
    }

    /// Bytes written so far.
    pub fn len(&self) -> usize {
        self.buf.len()
    }

    pub fn is_empty(&self) -> bool {
        self.buf.is_empty()
    }

    /// Bytes still available before the limit.
    pub fn remaining(&self) -> usize {
        self.max_len.saturating_sub(self.buf.len())
    }

    /// Messages written so far.
    pub fn message_count(&self) -> usize {
        self.messages
    }

    /// The frame so far.
    pub fn as_bytes(&self) -> &[u8] {
        &self.buf
    }

    fn reserve_message(&mut self, needed: usize) -> Result<(), EncodeError> {
        if self.messages >= MAX_MESSAGES_PER_FRAME {
            return Err(EncodeError::TooManyMessages {
                max: MAX_MESSAGES_PER_FRAME,
            });
        }
        if needed > self.remaining() {
            return Err(EncodeError::FrameFull {
                needed,
                available: self.remaining(),
            });
        }
        self.buf.reserve(needed);
        Ok(())
    }

    /// Appends a message if it fits.
    pub fn push<M: Message>(&mut self, m: &M) -> Result<(), EncodeError> {
        m.validate()?;
        self.reserve_message(m.encoded_len())?;
        encode_message_into(m, &mut self.buf)?;
        self.messages += 1;
        Ok(())
    }

    /// Takes the finished frame and resets the builder (keeping its allocation).
    pub fn finish(&mut self) -> Bytes {
        self.messages = 0;
        self.buf.split().freeze()
    }

    /// Discards everything written.
    pub fn clear(&mut self) {
        self.messages = 0;
        self.buf.clear();
    }

    fn begin_batch<E: Wire>(
        &mut self,
        type_id: u8,
        header: &[u8],
        cap: u8,
    ) -> Result<Batch<'_, E>, EncodeError> {
        self.reserve_message(MSG_HEADER_LEN + header.len() + 1)?;
        let start = self.buf.len();
        self.buf.put_u8(type_id);
        self.buf.put_u16_le(0);
        self.buf.put_slice(header);
        let count_at = self.buf.len();
        self.buf.put_u8(0);
        self.messages += 1;
        Ok(Batch {
            fb: self,
            start,
            count_at,
            count: 0,
            cap,
            _entry: PhantomData,
        })
    }

    /// Streams a `PlayerStates` message.
    pub fn player_states(&mut self) -> Result<Batch<'_, PlayerStateEntry>, EncodeError> {
        self.begin_batch(type_id::PLAYER_STATES, &[], MAX_ROOM_PLAYERS)
    }

    /// Streams a `TrafficSpawn` message.
    pub fn traffic_spawns(&mut self) -> Result<Batch<'_, TrafficSpawnEntry>, EncodeError> {
        self.begin_batch(type_id::TRAFFIC_SPAWN, &[], MAX_TRAFFIC_BATCH)
    }

    /// Streams a `TrafficDespawn` message (car ids).
    pub fn traffic_despawns(&mut self) -> Result<Batch<'_, u16>, EncodeError> {
        self.begin_batch(type_id::TRAFFIC_DESPAWN, &[], MAX_TRAFFIC_BATCH)
    }

    /// Streams a `TrafficIntent` message.
    pub fn traffic_intents(&mut self) -> Result<Batch<'_, TrafficIntentEntry>, EncodeError> {
        self.begin_batch(type_id::TRAFFIC_INTENT, &[], MAX_INTENT_BATCH)
    }

    /// Streams a `TrafficCorrection` message for `tick`.
    pub fn traffic_corrections(
        &mut self,
        tick: u32,
    ) -> Result<Batch<'_, CorrectionEntry>, EncodeError> {
        self.begin_batch(
            type_id::TRAFFIC_CORRECTION,
            &tick.to_le_bytes(),
            MAX_TRAFFIC_BATCH,
        )
    }
}

/// A list message being streamed into a `FrameBuilder`. Entries are validated and written in
/// place; dropping the batch patches the length and count (or removes the message entirely
/// when it holds no entries). Start another batch of the same type when this one is full.
#[derive(Debug)]
pub struct Batch<'a, E: Wire> {
    fb: &'a mut FrameBuilder,
    start: usize,
    count_at: usize,
    count: u8,
    cap: u8,
    _entry: PhantomData<fn(&E)>,
}

impl<E: Wire> Batch<'_, E> {
    /// Appends an entry if the batch and the frame have room.
    pub fn push(&mut self, entry: &E) -> Result<(), EncodeError> {
        entry.validate()?;
        if self.count >= self.cap {
            return Err(EncodeError::BatchFull {
                max: usize::from(self.cap),
            });
        }
        let needed = entry.wire_len();
        if needed > self.fb.remaining() {
            return Err(EncodeError::FrameFull {
                needed,
                available: self.fb.remaining(),
            });
        }
        entry.write(&mut self.fb.buf);
        self.count += 1;
        Ok(())
    }

    pub fn len(&self) -> usize {
        usize::from(self.count)
    }

    pub fn is_empty(&self) -> bool {
        self.count == 0
    }

    pub fn is_full(&self) -> bool {
        self.count >= self.cap
    }

    /// Ends the batch (same as dropping it).
    pub fn finish(self) {}
}

impl<E: Wire> Drop for Batch<'_, E> {
    fn drop(&mut self) {
        if self.count == 0 {
            self.fb.buf.truncate(self.start);
            self.fb.messages -= 1;
            return;
        }
        // The frame limit (<= 16 KB) keeps every payload within u16.
        let payload = self.fb.buf.len() - self.start - MSG_HEADER_LEN;
        let len = u16::try_from(payload).unwrap_or(u16::MAX).to_le_bytes();
        if let Some(slot) = self
            .fb
            .buf
            .get_mut(self.start + 1..self.start + MSG_HEADER_LEN)
        {
            slot.copy_from_slice(&len);
        }
        if let Some(slot) = self.fb.buf.get_mut(self.count_at) {
            *slot = self.count;
        }
    }
}
