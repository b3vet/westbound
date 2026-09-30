//! Shadow contacts to SQLite (N10.1). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Players
//! (shadow collision logging), Data model (`shadow_contacts`). Rooms hand every contact
//! between two players to [`db_sink`] (via `Rooms::set_shadow_sink`); it writes one row per
//! contact off the room task, at most `MAX_IN_FLIGHT` writes at a time (more are dropped
//! and counted: the room never waits). [`summary`] reads the recent rows back for the
//! admin stats.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use serde::Serialize;
use sqlx::SqlitePool;

use super::metrics::RoomMetrics;
use super::{ShadowRow, ShadowSink};

/// Writes in flight at once; a burst beyond this is dropped (`wb_room_shadow_rows_dropped`).
const MAX_IN_FLIGHT: usize = 64;

/// A sink that writes each contact to `shadow_contacts`.
pub fn db_sink(db: SqlitePool, metrics: Arc<RoomMetrics>) -> ShadowSink {
    let in_flight = Arc::new(AtomicUsize::new(0));
    Arc::new(move |row: ShadowRow| {
        let Ok(handle) = tokio::runtime::Handle::try_current() else {
            RoomMetrics::inc(&metrics.shadow_rows_dropped);
            return;
        };
        if in_flight.fetch_add(1, Ordering::Relaxed) >= MAX_IN_FLIGHT {
            in_flight.fetch_sub(1, Ordering::Relaxed);
            RoomMetrics::inc(&metrics.shadow_rows_dropped);
            return;
        }
        let (db, metrics, in_flight) = (db.clone(), metrics.clone(), in_flight.clone());
        handle.spawn(async move {
            match insert(&db, &row).await {
                Ok(()) => RoomMetrics::inc(&metrics.shadow_rows_written),
                Err(e) => {
                    RoomMetrics::inc(&metrics.shadow_rows_dropped);
                    tracing::warn!(error = %e, room = row.room_id, "shadow contact not written");
                }
            }
            in_flight.fetch_sub(1, Ordering::Relaxed);
        });
    })
}

/// Writes one contact (accounts ordered a < b).
pub async fn insert(db: &SqlitePool, row: &ShadowRow) -> anyhow::Result<()> {
    let (a, b) = {
        let (x, y) = (row.account_a.0, row.account_b.0);
        (i64::try_from(x.min(y))?, i64::try_from(x.max(y))?)
    };
    let (room, tick, ticks) = (
        i64::from(row.room_id),
        i64::from(row.tick),
        i64::from(row.ticks),
    );
    sqlx::query!(
        "INSERT INTO shadow_contacts \
         (room_id, tick, player_a, player_b, speed, disagreement_m, closing_mps, depth_m, ticks, \
          created_at) \
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        room,
        tick,
        a,
        b,
        row.speed_mps,
        row.disagreement_m,
        row.closing_mps,
        row.depth_m,
        ticks,
        row.at,
    )
    .execute(db)
    .await?;
    Ok(())
}

/// The contacts written since a time (the admin stats).
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize)]
pub struct Summary {
    /// Unix seconds the window starts at.
    pub since: i64,
    pub contacts: i64,
    /// Distinct account pairs.
    pub pairs: i64,
    pub mean_speed_kmh: f64,
    pub mean_disagreement_m: f64,
    pub max_disagreement_m: f64,
    /// Contacts whose views disagreed by more than 1 m (the soft-solid question: would
    /// players have felt a push where the other saw none?).
    pub over_1m: i64,
    pub mean_ticks: f64,
}

const KMH_PER_MPS: f64 = 3.6;

/// Aggregates of the contacts written since `since` (unix seconds).
pub async fn summary(db: &SqlitePool, since: i64) -> anyhow::Result<Summary> {
    let r = sqlx::query!(
        r#"SELECT COUNT(*) AS "contacts!: i64",
                  COUNT(DISTINCT player_a || ':' || player_b) AS "pairs!: i64",
                  COALESCE(AVG(speed), 0.0) AS "speed!: f64",
                  COALESCE(AVG(disagreement_m), 0.0) AS "dis!: f64",
                  COALESCE(MAX(disagreement_m), 0.0) AS "dis_max!: f64",
                  COALESCE(SUM(disagreement_m > 1.0), 0) AS "over!: i64",
                  COALESCE(AVG(ticks), 0.0) AS "ticks!: f64"
           FROM shadow_contacts WHERE created_at >= ?"#,
        since
    )
    .fetch_one(db)
    .await?;
    Ok(Summary {
        since,
        contacts: r.contacts,
        pairs: r.pairs,
        mean_speed_kmh: r.speed * KMH_PER_MPS,
        mean_disagreement_m: r.dis,
        max_disagreement_m: r.dis_max,
        over_1m: r.over,
        mean_ticks: r.ticks,
    })
}
