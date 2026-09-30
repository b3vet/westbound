//! Periodic operational probes for `/metrics` (N10.2): database latency and sizes, the
//! pool, and the queue depths that live in the database (replay verification jobs,
//! unhandled reports). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Server tech stack"
//! (logging and metrics). Runbook: docs/OPERATIONS.md → Metrics.

use std::path::Path;
use std::time::{Duration, Instant};

use sqlx::SqlitePool;

use crate::app::AppState;
use crate::metrics::{Metrics, REPLAY_STATUSES};

/// Every `metrics.db_probe_interval_secs` until shutdown.
pub async fn db_probe(state: AppState) {
    let every = Duration::from_secs(state.config.metrics.db_probe_interval_secs.max(1));
    let mut tick = tokio::time::interval(every);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tokio::select! {
            _ = state.shutdown.cancelled() => return,
            _ = tick.tick() => {}
        }
        probe_once(&state.db, &state.config.db.path, &state.metrics).await;
    }
}

/// One probe: a timed query through the pool, the pool's size, the file sizes, the queues.
pub async fn probe_once(db: &SqlitePool, db_path: &Path, m: &Metrics) {
    let t0 = Instant::now();
    let ok = sqlx::query_scalar::<_, i64>("SELECT 1")
        .fetch_one(db)
        .await
        .is_ok();
    if ok {
        Metrics::set(
            &m.db_probe_micros,
            u64::try_from(t0.elapsed().as_micros()).unwrap_or(u64::MAX),
        );
    } else {
        Metrics::inc(&m.db_probe_failures);
    }
    Metrics::set(&m.db_pool_size, u64::from(db.size()));
    Metrics::set(&m.db_pool_idle, db.num_idle() as u64);
    Metrics::set(&m.db_file_bytes, file_len(db_path));
    Metrics::set(&m.db_wal_bytes, file_len(&wal_path(db_path)));
    match sqlx::query_as::<_, (String, i64)>("SELECT status, COUNT(*) FROM replays GROUP BY status")
        .fetch_all(db)
        .await
    {
        Ok(rows) => {
            for st in REPLAY_STATUSES {
                let n = rows.iter().find(|(s, _)| s == st).map_or(0, |(_, n)| *n);
                m.set_replay_jobs(st, u64::try_from(n).unwrap_or(0));
            }
        }
        Err(e) => tracing::debug!(error = %e, "replay queue probe failed"),
    }
    if let Ok(n) = sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM reports WHERE handled = 0")
        .fetch_one(db)
        .await
    {
        Metrics::set(&m.reports_unhandled, u64::try_from(n).unwrap_or(0));
    }
}

fn file_len(p: &Path) -> u64 {
    std::fs::metadata(p).map(|m| m.len()).unwrap_or(0)
}

/// `<db>-wal`.
pub fn wal_path(db_path: &Path) -> std::path::PathBuf {
    let mut s = db_path.as_os_str().to_owned();
    s.push("-wal");
    s.into()
}
