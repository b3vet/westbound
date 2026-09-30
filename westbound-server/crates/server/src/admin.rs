//! Admin commands behind `westbound-server admin ...`: ban, unban, force-rename, (N7.1)
//! remove a run or a leaderboard entry, and (N9.1) list and handle reports, rename or
//! disband a crew. Each change is recorded in `admin_log` (actor `cli`). Spec:
//! WESTBOUND_MULTIPLAYER_HANDOFF.md → "Moderation" (admin CLI: list reports, ban or unban
//! with duration, force-rename, and remove a run or leaderboard entry).

use anyhow::{bail, Context};
use sqlx::SqlitePool;

use crate::accounts::{self, PERMANENT_BAN_UNTIL};
use crate::config::LeaderboardsConfig;
use crate::leaderboards::{self, Board};
use crate::names;
use crate::profanity::ProfanityFilter;
use crate::social;

const ACTOR: &str = "cli";

/// `30m`, `12h`, `7d`, `2w` → seconds; `perm` / `permanent` → `None` (permanent).
pub fn parse_duration(s: &str) -> anyhow::Result<Option<i64>> {
    let s = s.trim();
    if matches!(s, "perm" | "permanent" | "forever") {
        return Ok(None);
    }
    let (num, unit) = s.split_at(s.len().saturating_sub(1));
    let n: i64 = num
        .parse()
        .ok()
        .filter(|&n| n > 0)
        .with_context(|| format!("duration `{s}`: expected <n>m, <n>h, <n>d, <n>w or perm"))?;
    let mult = match unit {
        "m" => 60,
        "h" => 3_600,
        "d" => 86_400,
        "w" => 7 * 86_400,
        _ => bail!("duration `{s}`: unit must be m, h, d or w (or `perm`)"),
    };
    n.checked_mul(mult)
        .map(Some)
        .context("duration too long; use `perm`")
}

async fn require_account(pool: &SqlitePool, id: i64) -> anyhow::Result<accounts::Account> {
    accounts::get(pool, id)
        .await?
        .with_context(|| format!("no account {id}"))
}

/// Bans an account until `now + duration` (or permanently).
pub async fn ban(pool: &SqlitePool, id: i64, duration: &str, now: i64) -> anyhow::Result<String> {
    let secs = parse_duration(duration)?;
    require_account(pool, id).await?;
    let until = secs.map_or(PERMANENT_BAN_UNTIL, |d| {
        now.saturating_add(d).min(PERMANENT_BAN_UNTIL)
    });
    accounts::set_ban(pool, id, Some(until)).await?;
    let detail = format!("until={until} duration={duration}");
    crate::db::admin_log(pool, ACTOR, "ban", &id.to_string(), &detail).await?;
    Ok(if secs.is_none() {
        format!("account {id} banned permanently")
    } else {
        format!("account {id} banned until {until} (unix seconds)")
    })
}

pub async fn unban(pool: &SqlitePool, id: i64) -> anyhow::Result<String> {
    require_account(pool, id).await?;
    accounts::set_ban(pool, id, None).await?;
    crate::db::admin_log(pool, ACTOR, "unban", &id.to_string(), "").await?;
    Ok(format!("account {id} unbanned"))
}

/// Force-renames an account (validation and profanity filter apply; the 30-day
/// cooldown does not, and the player's own cooldown restarts).
pub async fn rename(pool: &SqlitePool, id: i64, name: &str, now: i64) -> anyhow::Result<String> {
    let name = names::validate(name, ProfanityFilter::builtin())
        .map_err(|e| anyhow::anyhow!("name `{name}`: {e}"))?;
    let before = require_account(pool, id).await?;
    let acc = accounts::rename(pool, id, &name, now, None)
        .await
        .map_err(|e| anyhow::anyhow!("rename failed: {e}"))?;
    let full = names::full_name(&acc.display_name, acc.tag);
    let detail = format!(
        "from={} to={full}",
        names::full_name(&before.display_name, before.tag)
    );
    crate::db::admin_log(pool, ACTOR, "rename", &id.to_string(), &detail).await?;
    Ok(format!("account {id} renamed to {full}"))
}

/// Replay jobs (N8.1): `replays` lists the queue by status; `replay_requeue` puts a
/// `failed` job (or with `run_id` any job whose file is still there) back to `pending`
/// with its attempts reset. The server's worker picks it up within
/// `replays.poll_interval_secs`.
pub async fn replays(pool: &SqlitePool) -> anyhow::Result<String> {
    let rows = sqlx::query!(
        r#"SELECT status, COUNT(*) AS "n!: i64" FROM replays GROUP BY status ORDER BY status"#
    )
    .fetch_all(pool)
    .await?;
    let mut out: Vec<String> = rows
        .into_iter()
        .map(|r| format!("{} {}", r.status, r.n))
        .collect();
    let failed = sqlx::query!(
        "SELECT run_id, attempts, result FROM replays WHERE status = 'failed' ORDER BY run_id LIMIT 20"
    )
    .fetch_all(pool)
    .await?;
    for f in failed {
        out.push(format!(
            "failed run {} after {} attempts: {}",
            f.run_id,
            f.attempts,
            f.result.unwrap_or_default()
        ));
    }
    if out.is_empty() {
        return Ok("no replays".into());
    }
    Ok(out.join("\n"))
}

pub async fn replay_requeue(pool: &SqlitePool, run_id: Option<i64>) -> anyhow::Result<String> {
    let done = match run_id {
        Some(id) => {
            sqlx::query!(
                "UPDATE replays SET status = 'pending', attempts = 0, not_before = 0, verdict = NULL
                 WHERE run_id = ? AND file_deleted_at IS NULL",
                id
            )
            .execute(pool)
            .await?
        }
        None => {
            sqlx::query!(
                "UPDATE replays SET status = 'pending', attempts = 0, not_before = 0
                 WHERE status = 'failed' AND file_deleted_at IS NULL"
            )
            .execute(pool)
            .await?
        }
    };
    let n = done.rows_affected();
    let target = run_id.map_or_else(|| "failed".to_string(), |id| id.to_string());
    crate::db::admin_log(pool, ACTOR, "replay_requeue", &target, &format!("jobs={n}")).await?;
    Ok(format!("{n} replay job(s) requeued"))
}

/// Deletes a run (and its replay) and rebuilds every leaderboard entry it held from the
/// player's next best run. A running server's cached board tops catch up within
/// `leaderboards.cache_ttl_secs`.
pub async fn remove_run(
    pool: &SqlitePool,
    cfg: &LeaderboardsConfig,
    run_id: i64,
) -> anyhow::Result<String> {
    let removed = leaderboards::remove_run(pool, cfg, run_id)
        .await?
        .with_context(|| format!("no run {run_id}"))?;
    let entries: Vec<String> = removed
        .entries
        .iter()
        .map(|(b, p)| format!("{b}/{p}"))
        .collect();
    let detail = format!(
        "account={} entries={} replay={}",
        removed.account_id,
        entries.join(","),
        removed.replay_file.is_some()
    );
    crate::db::admin_log(pool, ACTOR, "remove_run", &run_id.to_string(), &detail).await?;
    Ok(format!(
        "run {run_id} of account {} removed; entries rebuilt: {}",
        removed.account_id,
        if entries.is_empty() {
            "none".to_string()
        } else {
            entries.join(", ")
        }
    ))
}

/// Deletes one leaderboard entry (`board` id, `period` key, account id, or crew id on
/// `loop_crew`). It is not rebuilt from older runs: it comes back only with a new run.
pub async fn remove_entry(
    pool: &SqlitePool,
    board: &str,
    period: &str,
    subject_id: i64,
) -> anyhow::Result<String> {
    let b = Board::parse(board).with_context(|| {
        format!("board `{board}`: expected loop, loop_crew, journey, daily or distance")
    })?;
    let p = b
        .parse_period(period)
        .with_context(|| format!("period `{period}` is not one board `{board}` keeps"))?;
    if !leaderboards::remove_entry(pool, b, &p, subject_id).await? {
        bail!("no entry for {subject_id} on {board}/{period}");
    }
    let target = format!("{board}/{period}/{subject_id}");
    crate::db::admin_log(pool, ACTOR, "remove_entry", &target, "").await?;
    Ok(format!("entry {target} removed"))
}

/// Lists reports, newest first: one line each (`--unhandled`: only those not handled
/// yet), at most `limit`. A deleted reporter or target shows as `deleted`.
pub async fn reports(
    pool: &SqlitePool,
    unhandled_only: bool,
    limit: i64,
) -> anyhow::Result<String> {
    let rows = social::reports::list(pool, unhandled_only, limit.max(1)).await?;
    if rows.is_empty() {
        return Ok(if unhandled_only {
            "no unhandled reports".to_string()
        } else {
            "no reports".to_string()
        });
    }
    let side = |id: Option<i64>| id.map_or("deleted".to_string(), |i| i.to_string());
    let lines: Vec<String> = rows
        .iter()
        .map(|r| {
            format!(
                "#{} {} reporter={} target={} reason={} {} context={}",
                r.id,
                r.created_at,
                side(r.reporter_id),
                side(r.target_id),
                r.reason,
                match r.handled_at {
                    Some(t) if r.handled => format!("handled={t}"),
                    _ => "unhandled".to_string(),
                },
                r.context
            )
        })
        .collect();
    Ok(lines.join("\n"))
}

/// Marks a report handled.
pub async fn report_handle(pool: &SqlitePool, id: i64, now: i64) -> anyhow::Result<String> {
    match social::reports::mark_handled(pool, id, now).await? {
        None => bail!("no report {id}"),
        Some(false) => Ok(format!("report {id} was already handled")),
        Some(true) => {
            crate::db::admin_log(pool, ACTOR, "report_handle", &id.to_string(), "").await?;
            Ok(format!("report {id} marked handled"))
        }
    }
}

/// Force-renames a crew and/or changes its tag (name and tag rules, the filter and
/// uniqueness apply).
pub async fn crew_rename(
    pool: &SqlitePool,
    crew_id: i64,
    name: Option<&str>,
    tag: Option<&str>,
) -> anyhow::Result<String> {
    if name.is_none() && tag.is_none() {
        bail!("give a new name, --tag, or both");
    }
    let before = sqlx::query!("SELECT name, tag FROM crews WHERE id = ?", crew_id)
        .fetch_optional(pool)
        .await?
        .with_context(|| format!("no crew {crew_id}"))?;
    let (name, tag) = social::crews::admin_rename(pool, crew_id, name, tag)
        .await
        .map_err(|e| anyhow::anyhow!("{} ({})", e.message, e.code))?;
    let detail = format!("from={} [{}] to={name} [{tag}]", before.name, before.tag);
    crate::db::admin_log(pool, ACTOR, "crew_rename", &crew_id.to_string(), &detail).await?;
    Ok(format!("crew {crew_id} renamed to {name} [{tag}]"))
}

/// Disbands a crew: its memberships and Loop crew entries go. A running server's cached
/// board tops catch up within `leaderboards.cache_ttl_secs`.
pub async fn crew_disband(pool: &SqlitePool, crew_id: i64) -> anyhow::Result<String> {
    let mut tx = pool.begin_with("BEGIN IMMEDIATE").await?;
    let members = social::crews::member_ids(&mut tx, crew_id).await?;
    if !social::crews::disband_rows(&mut tx, crew_id).await? {
        bail!("no crew {crew_id}");
    }
    crate::db::admin_log(
        &mut *tx,
        ACTOR,
        "crew_disband",
        &crew_id.to_string(),
        &format!("members={}", members.len()),
    )
    .await?;
    tx.commit().await?;
    Ok(format!(
        "crew {crew_id} disbanded ({} members released)",
        members.len()
    ))
}

#[cfg(test)]
mod tests {
    use super::parse_duration;

    #[test]
    fn durations() {
        assert_eq!(parse_duration("30m").unwrap(), Some(1_800));
        assert_eq!(parse_duration("12h").unwrap(), Some(43_200));
        assert_eq!(parse_duration("7d").unwrap(), Some(604_800));
        assert_eq!(parse_duration("2w").unwrap(), Some(1_209_600));
        assert_eq!(parse_duration("perm").unwrap(), None);
        for bad in [
            "",
            "7",
            "d",
            "0d",
            "-1d",
            "7y",
            "1.5h",
            "99999999999999999w",
        ] {
            assert!(parse_duration(bad).is_err(), "{bad}");
        }
    }
}
