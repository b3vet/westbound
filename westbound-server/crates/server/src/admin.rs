//! Admin commands behind `westbound-server admin ...`: ban, unban, force-rename, and
//! (N7.1) remove a run or a leaderboard entry. Each one is recorded in `admin_log` (actor
//! `cli`). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Moderation" (admin CLI: ban or unban
//! with duration, force-rename, and remove a run or leaderboard entry).

use anyhow::{bail, Context};
use sqlx::SqlitePool;

use crate::accounts::{self, PERMANENT_BAN_UNTIL};
use crate::config::LeaderboardsConfig;
use crate::leaderboards::{self, Board};
use crate::names;
use crate::profanity::ProfanityFilter;

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
