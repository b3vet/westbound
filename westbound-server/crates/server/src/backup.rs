//! Nightly online backup with retention. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md →
//! "Resource budget and deployment" (nightly `.backup` to a dated file, 7-day
//! retention); docs/MULTIPLAYER_PLAN.md MP-D1 (a scheduled task inside the server).

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use sqlx::SqlitePool;
use tokio_util::sync::CancellationToken;

use crate::clock::{self, SECS_PER_DAY};
use crate::config::{parse_hh_mm, BackupConfig};
use crate::metrics::Metrics;

const FILE_PREFIX: &str = "westbound-";
const FILE_SUFFIX: &str = ".db";
const SECS_PER_MINUTE: i64 = 60;

/// `westbound-YYYY-MM-DD.db` for the UTC date of `unix_secs`.
pub fn dated_file_name(unix_secs: i64) -> String {
    format!(
        "{FILE_PREFIX}{}{FILE_SUFFIX}",
        clock::utc_date_string(unix_secs)
    )
}

/// Next unix time strictly after `now` at `minutes_utc` past UTC midnight.
pub fn next_run_after(now: i64, minutes_utc: u32) -> i64 {
    let midnight = now.div_euclid(SECS_PER_DAY) * SECS_PER_DAY;
    let today = midnight + i64::from(minutes_utc) * SECS_PER_MINUTE;
    if today > now {
        today
    } else {
        today + SECS_PER_DAY
    }
}

/// Writes today's dated backup (replacing an earlier one from the same day), then
/// prunes old files. Returns the backup path.
pub async fn run_once(pool: &SqlitePool, cfg: &BackupConfig, now: i64) -> anyhow::Result<PathBuf> {
    tokio::fs::create_dir_all(&cfg.dir).await?;
    let name = dated_file_name(now);
    let dest = cfg.dir.join(&name);
    let tmp = cfg.dir.join(format!("{name}.tmp"));
    let _ = tokio::fs::remove_file(&tmp).await;
    crate::db::backup_to(pool, &tmp).await?;
    tokio::fs::rename(&tmp, &dest).await?;
    let removed = prune(&cfg.dir, cfg.retention_days, now)?;
    let detail = format!("removed {} old", removed.len());
    crate::db::admin_log(pool, "system", "backup", &name, &detail).await?;
    Ok(dest)
}

/// Deletes `westbound-YYYY-MM-DD.db` files dated `retention_days` or more days
/// before `now`'s date (so exactly `retention_days` dated files remain). Other
/// files are left alone.
pub fn prune(dir: &Path, retention_days: u32, now: i64) -> std::io::Result<Vec<PathBuf>> {
    let today = now.div_euclid(SECS_PER_DAY);
    let mut removed = Vec::new();
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        let Some(date) = name
            .strip_prefix(FILE_PREFIX)
            .and_then(|r| r.strip_suffix(FILE_SUFFIX))
        else {
            continue;
        };
        let Some(days) = clock::parse_date_days(date) else {
            continue;
        };
        if today - days >= i64::from(retention_days) {
            std::fs::remove_file(entry.path())?;
            removed.push(entry.path());
        }
    }
    removed.sort();
    Ok(removed)
}

/// The scheduled task: sleeps until `time_utc`, backs up, repeats until cancelled.
pub async fn nightly(
    pool: SqlitePool,
    cfg: BackupConfig,
    metrics: Arc<Metrics>,
    cancel: CancellationToken,
) {
    let Some(minutes) = parse_hh_mm(&cfg.time_utc) else {
        return;
    };
    loop {
        let now = clock::unix_now_secs();
        let wait = (next_run_after(now, minutes) - now).max(0) as u64;
        tracing::info!(in_secs = wait, dir = %cfg.dir.display(), "next nightly backup scheduled");
        tokio::select! {
            _ = cancel.cancelled() => return,
            _ = tokio::time::sleep(Duration::from_secs(wait)) => {}
        }
        match run_once(&pool, &cfg, clock::unix_now_secs()).await {
            Ok(path) => {
                Metrics::inc(&metrics.backups_ok);
                tracing::info!(path = %path.display(), "nightly backup written");
            }
            Err(e) => {
                Metrics::inc(&metrics.backups_failed);
                tracing::error!(error = %format!("{e:#}"), "nightly backup failed");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schedules_next_run() {
        let day = 20_000 * SECS_PER_DAY;
        let at = 3 * 60 + 17;
        assert_eq!(next_run_after(day, at), day + 3 * 3600 + 17 * 60);
        assert_eq!(
            next_run_after(day + 3 * 3600 + 17 * 60, at),
            day + SECS_PER_DAY + 3 * 3600 + 17 * 60
        );
        assert_eq!(
            next_run_after(day + 23 * 3600, at),
            day + SECS_PER_DAY + 3 * 3600 + 17 * 60
        );
    }

    #[test]
    fn prunes_old_dated_files_only() {
        let dir = tempfile::tempdir().unwrap();
        let now = clock::parse_date_days("2026-09-29").unwrap() * SECS_PER_DAY + 5_000;
        for name in [
            "westbound-2026-09-29.db",
            "westbound-2026-09-23.db",
            "westbound-2026-09-22.db",
            "westbound-2026-08-01.db",
            "westbound-not-a-date.db",
            "notes.txt",
        ] {
            std::fs::write(dir.path().join(name), b"x").unwrap();
        }
        let removed = prune(dir.path(), 7, now).unwrap();
        let removed: Vec<String> = removed
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        assert_eq!(
            removed,
            vec!["westbound-2026-08-01.db", "westbound-2026-09-22.db"]
        );
        assert!(dir.path().join("westbound-2026-09-23.db").exists());
        assert!(dir.path().join("notes.txt").exists());
    }
}
