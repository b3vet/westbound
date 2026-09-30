//! The `.wbr` replay header (docs/REPLAY_FORMAT.md → Header). The server reads only the
//! uncompressed header: it checks that an upload is a replay of the run it is posted
//! for; the Godot verifier reads the rest. Little-endian throughout.

/// `WBR1`.
pub const MAGIC: &[u8; 4] = b"WBR1";
pub const VERSION: u16 = 1;
/// Header bytes before the car id.
pub const FIXED_HEADER: usize = 77;
/// Where the run id sits (the client patches it in once the receipt names the run).
pub const RUN_ID_OFFSET: usize = 8;
pub const CAR_MAX: usize = 32;
pub const DATE_LEN: usize = 10;
pub const COMPRESSION_GZIP: u8 = 1;
pub const MODE_JOURNEY: u8 = 1;
pub const MODE_DAILY: u8 = 2;

/// The parsed header.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Header {
    pub run_id: i64,
    pub seed: i64,
    pub client_build: u32,
    pub tuning_hash: u32,
    /// `journey` or `daily`.
    pub mode: &'static str,
    pub tick_hz: u16,
    pub sample_ticks: u16,
    pub date: String,
    /// RUNNING ticks, the claimed banked score and hits, the distance (mm).
    pub ticks: u32,
    pub score: i64,
    pub hits: u32,
    pub distance_mm: u32,
    pub raw_len: u32,
    pub payload_len: u32,
    pub car: String,
    pub header_len: usize,
}

fn u16_at(b: &[u8], at: usize) -> u16 {
    u16::from_le_bytes([b[at], b[at + 1]])
}

fn u32_at(b: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(b[at..at + 4].try_into().expect("4 bytes"))
}

fn i64_at(b: &[u8], at: usize) -> i64 {
    i64::from_le_bytes(b[at..at + 8].try_into().expect("8 bytes"))
}

/// Parses and checks a whole file's header against its length. The error says why.
pub fn parse(b: &[u8]) -> Result<Header, String> {
    if b.len() < FIXED_HEADER {
        return Err(format!("too short: {} bytes", b.len()));
    }
    if &b[0..4] != MAGIC {
        return Err("not a replay (magic)".into());
    }
    let version = u16_at(b, 4);
    if version != VERSION {
        return Err(format!("unsupported version {version}"));
    }
    let header_len = usize::from(u16_at(b, 6));
    let car_len = usize::from(b[76]);
    if car_len == 0 || car_len > CAR_MAX || header_len != FIXED_HEADER + car_len {
        return Err("bad header length".into());
    }
    if header_len > b.len() {
        return Err("truncated header".into());
    }
    if b[33] != COMPRESSION_GZIP {
        return Err("unknown compression".into());
    }
    let mode = match b[32] {
        MODE_JOURNEY => "journey",
        MODE_DAILY => "daily",
        m => return Err(format!("bad mode {m}")),
    };
    let date = std::str::from_utf8(&b[38..38 + DATE_LEN])
        .map_err(|_| "bad date".to_string())?
        .to_string();
    let car = std::str::from_utf8(&b[FIXED_HEADER..header_len])
        .map_err(|_| "bad car id".to_string())?
        .to_string();
    let payload_len = u32_at(b, 72);
    if header_len + payload_len as usize != b.len() {
        return Err("the payload length does not match the file".into());
    }
    let payload = &b[header_len..];
    if payload.len() < 2 || payload[0] != 0x1f || payload[1] != 0x8b {
        return Err("the payload is not gzip".into());
    }
    let h = Header {
        run_id: i64_at(b, RUN_ID_OFFSET),
        seed: i64_at(b, 16),
        client_build: u32_at(b, 24),
        tuning_hash: u32_at(b, 28),
        mode,
        tick_hz: u16_at(b, 34),
        sample_ticks: u16_at(b, 36),
        date,
        ticks: u32_at(b, 48),
        score: i64_at(b, 52),
        hits: u32_at(b, 60),
        distance_mm: u32_at(b, 64),
        raw_len: u32_at(b, 68),
        payload_len,
        car,
        header_len,
    };
    if h.tick_hz == 0 || h.sample_ticks == 0 {
        return Err("bad rates".into());
    }
    if h.seed < 0 || h.score < 0 {
        return Err("negative seed or score".into());
    }
    Ok(h)
}

/// A minimal valid file for tests and tools: the header of `h` (run id, seed, build,
/// mode, date, car, claims) and a gzip payload `payload` (any bytes starting 1f 8b).
pub fn build(h: &Header, payload: &[u8]) -> Vec<u8> {
    let car = h.car.as_bytes();
    let header_len = FIXED_HEADER + car.len();
    let mut out = vec![0u8; header_len];
    out[0..4].copy_from_slice(MAGIC);
    out[4..6].copy_from_slice(&VERSION.to_le_bytes());
    out[6..8].copy_from_slice(&(header_len as u16).to_le_bytes());
    out[8..16].copy_from_slice(&h.run_id.to_le_bytes());
    out[16..24].copy_from_slice(&h.seed.to_le_bytes());
    out[24..28].copy_from_slice(&h.client_build.to_le_bytes());
    out[28..32].copy_from_slice(&h.tuning_hash.to_le_bytes());
    out[32] = if h.mode == "daily" {
        MODE_DAILY
    } else {
        MODE_JOURNEY
    };
    out[33] = COMPRESSION_GZIP;
    out[34..36].copy_from_slice(&h.tick_hz.to_le_bytes());
    out[36..38].copy_from_slice(&h.sample_ticks.to_le_bytes());
    let date = h.date.as_bytes();
    let n = date.len().min(DATE_LEN);
    out[38..38 + n].copy_from_slice(&date[..n]);
    out[48..52].copy_from_slice(&h.ticks.to_le_bytes());
    out[52..60].copy_from_slice(&h.score.to_le_bytes());
    out[60..64].copy_from_slice(&h.hits.to_le_bytes());
    out[64..68].copy_from_slice(&h.distance_mm.to_le_bytes());
    out[68..72].copy_from_slice(&h.raw_len.to_le_bytes());
    out[72..76].copy_from_slice(&(payload.len() as u32).to_le_bytes());
    out[76] = car.len() as u8;
    out[FIXED_HEADER..].copy_from_slice(car);
    out.extend_from_slice(payload);
    out
}

/// Writes `run_id` into an encoded file's header.
pub fn patch_run_id(b: &mut [u8], run_id: i64) -> bool {
    if b.len() < FIXED_HEADER || &b[0..4] != MAGIC {
        return false;
    }
    b[RUN_ID_OFFSET..RUN_ID_OFFSET + 8].copy_from_slice(&run_id.to_le_bytes());
    true
}
