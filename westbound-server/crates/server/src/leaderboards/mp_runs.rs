//! The multiplayer write path (N6.1 → N7's hook). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md
//! → Leaderboards: "Multiplayer runs go on the boards automatically. The server already
//! holds the official score, so nothing is submitted by the client."
//!
//! Rooms hand every finished **verified** run to [`run_sink`] (their eligibility rules,
//! MP-D7 and MP-D9, are the room's); it writes it off the room task: the player's crew
//! snapshot (`social::crew_snapshot`), then [`Leaderboards::record_multiplayer_run`] (Loop
//! for ranked rooms, the crew's Loop crew score). Failures are logged, never retried: the
//! room has moved on.

use std::sync::Arc;

use sqlx::SqlitePool;

use super::{Leaderboards, MultiplayerRun};
use crate::rooms::{FinishedRun, RunSink};

/// The car and build a multiplayer run is stored with: `PlayerState` carries neither (not
/// in the protocol), so the run rows say so.
pub const UNKNOWN_CAR: &str = "unknown";
pub const UNKNOWN_BUILD: u32 = 0;

/// A sink that writes finished runs on `map_id` to the boards (spawns a task per run).
pub fn run_sink(boards: Arc<Leaderboards>, db: SqlitePool, map_id: String) -> RunSink {
    Arc::new(move |run: FinishedRun| {
        let (boards, db, map_id) = (boards.clone(), db.clone(), map_id.clone());
        let Ok(handle) = tokio::runtime::Handle::try_current() else {
            tracing::warn!("no runtime to record a multiplayer run");
            return;
        };
        handle.spawn(async move {
            if let Err(e) = record(&boards, &db, map_id, &run).await {
                tracing::warn!(error = %e, account = run.account.0, "multiplayer run not recorded");
            }
        });
    })
}

/// Writes one run (its crew snapshot first).
pub async fn record(
    boards: &Leaderboards,
    db: &SqlitePool,
    map_id: String,
    run: &FinishedRun,
) -> anyhow::Result<()> {
    let account_id = i64::try_from(run.account.0)?;
    let crew = {
        let mut conn = db.acquire().await?;
        crate::social::crew_snapshot(&mut conn, account_id).await?
    };
    let recorded = boards
        .record_multiplayer_run(&MultiplayerRun {
            account_id,
            map_id,
            room: run.room,
            score: run.result.score,
            duration_s: run.duration_s,
            distance_m: run.distance_m,
            stats: serde_json::to_value(&run.result)?,
            car: UNKNOWN_CAR.into(),
            client_build: UNKNOWN_BUILD,
            ended_at: run.ended_at,
            crew,
        })
        .await?;
    tracing::info!(
        account = account_id,
        run = recorded.run_id,
        ranked = recorded.ranked,
        score = run.result.score,
        "multiplayer run recorded"
    );
    Ok(())
}
