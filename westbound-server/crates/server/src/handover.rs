//! The planned-restart room handover (N10.2). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md →
//! "Resource budget and deployment" ("the server broadcasts a notice 60 seconds before a
//! planned restart. Clients reconnect automatically and rejoin the same private room by
//! code, or Quick Join again").
//!
//! Room state lives in memory, so a restart loses it. At the end of the restart notice the
//! old instance closes every room (runs end as `room_closed`, verified ones reach the
//! boards) and writes each room's **code and settings** to `room-handover.json` next to the
//! database, on the persistent volume. The next instance reads that file when a player
//! joins by a code it does not know: a handed-over code (within `server.handover_ttl_secs`)
//! is recreated with the same settings and the player takes a fresh seat in it. So a
//! reconnecting client simply repeats its `room_join_code`, public and private rooms alike.
//! This works whether the new instance starts after the old one exits (compose recreate) or
//! alongside it (a rolling update): the file is read when the join arrives, not at startup.
//!
//! What does not survive: seats and runs (the run ended with its banked score kept, as for a
//! reconnect after the 15 s seat hold), the host (it goes to the first player back), the
//! kick list, parties (in memory; the client rejoins the room without them).

use std::path::{Path, PathBuf};

use anyhow::Context;
use protocol::{Code, RoomSettings};
use serde::{Deserialize, Serialize};

/// The file name, next to `db.path`.
pub const FILE_NAME: &str = "room-handover.json";

/// One handed-over room.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HandedOver {
    pub code: String,
    pub settings: RoomSettings,
}

/// The file's content.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Handover {
    /// Unix seconds when it was written.
    pub saved_at: i64,
    /// Unix seconds after which it is ignored.
    pub expires_at: i64,
    pub rooms: Vec<HandedOver>,
}

impl Handover {
    /// The settings of `code` if it was handed over and has not expired at `now`.
    pub fn find(&self, code: &Code, now: i64) -> Option<RoomSettings> {
        if now >= self.expires_at {
            return None;
        }
        self.rooms
            .iter()
            .find(|r| r.code == code.0)
            .map(|r| r.settings.clone())
    }
}

/// `room-handover.json` beside the database file.
pub fn path_for(db_path: &Path) -> PathBuf {
    db_path.with_file_name(FILE_NAME)
}

/// Writes the handover atomically (a temp file, then a rename). An empty room list still
/// writes (it replaces an older file).
pub async fn save(
    path: &Path,
    rooms: &[(Code, RoomSettings)],
    now: i64,
    ttl_secs: u64,
) -> anyhow::Result<()> {
    let h = Handover {
        saved_at: now,
        expires_at: now.saturating_add(i64::try_from(ttl_secs).unwrap_or(i64::MAX)),
        rooms: rooms
            .iter()
            .map(|(c, s)| HandedOver {
                code: c.0.clone(),
                settings: s.clone(),
            })
            .collect(),
    };
    let json = serde_json::to_vec_pretty(&h)?;
    if let Some(dir) = path.parent() {
        if !dir.as_os_str().is_empty() {
            tokio::fs::create_dir_all(dir).await?;
        }
    }
    let tmp = path.with_extension("json.tmp");
    tokio::fs::write(&tmp, &json)
        .await
        .with_context(|| format!("writing {}", tmp.display()))?;
    tokio::fs::rename(&tmp, path)
        .await
        .with_context(|| format!("renaming to {}", path.display()))?;
    Ok(())
}

/// Reads the handover (None: no file, or unreadable, which is logged).
pub async fn load(path: &Path) -> Option<Handover> {
    let bytes = match tokio::fs::read(path).await {
        Ok(b) => b,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return None,
        Err(e) => {
            tracing::warn!(error = %e, path = %path.display(), "cannot read the room handover");
            return None;
        }
    };
    match serde_json::from_slice(&bytes) {
        Ok(h) => Some(h),
        Err(e) => {
            tracing::warn!(error = %e, path = %path.display(), "room handover is not valid JSON");
            None
        }
    }
}

/// The settings to recreate `code` with, if the previous instance handed it over.
pub async fn lookup(path: &Path, code: &Code, now: i64) -> Option<RoomSettings> {
    load(path).await?.find(code, now)
}

#[cfg(test)]
mod tests {
    use super::*;
    use protocol::{Density, TimeMode, Visibility};

    fn settings(d: Density) -> RoomSettings {
        RoomSettings {
            visibility: Visibility::Private,
            max_players: 4,
            density: d,
            time_mode: TimeMode::Fixed,
            fixed_cycle_ms: 123_000,
        }
    }

    #[tokio::test]
    async fn save_then_lookup_until_expiry() {
        let dir = tempfile::tempdir().unwrap();
        let path = path_for(&dir.path().join("westbound.db"));
        assert_eq!(path.file_name().unwrap(), FILE_NAME);
        let a = Code("ABC234".into());
        let b = Code("XYZ789".into());
        assert!(lookup(&path, &a, 100).await.is_none(), "no file yet");
        save(&path, &[(a.clone(), settings(Density::Rush))], 1_000, 600)
            .await
            .unwrap();
        assert_eq!(
            lookup(&path, &a, 1_000).await,
            Some(settings(Density::Rush))
        );
        assert!(lookup(&path, &b, 1_000).await.is_none());
        assert!(lookup(&path, &a, 1_600).await.is_none(), "expired");
        // A later save replaces the file.
        save(&path, &[(b.clone(), settings(Density::Light))], 2_000, 600)
            .await
            .unwrap();
        assert!(lookup(&path, &a, 2_000).await.is_none());
        assert!(lookup(&path, &b, 2_000).await.is_some());
        // Garbage is ignored, not fatal.
        std::fs::write(&path, b"{nope").unwrap();
        assert!(lookup(&path, &b, 2_000).await.is_none());
    }
}
