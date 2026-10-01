//! Admin commands behind `westbound-server admin ...`: ban, unban, force-rename, (N7.1)
//! remove a run or a leaderboard entry, and (N9.1) list and handle reports, rename or
//! disband a crew; (N10.2) player lookup by `name#tag` or id, ban reasons, player deletion,
//! board recomputes, database stats, the admin log and the backup list; (N10.3) the
//! set-aside replay jobs and their purge, the backups' freshness and the disk numbers.
//! Each change is
//! recorded in `admin_log` (actor `cli`). The live commands (rooms, notices, kicks) go
//! through the running server's admin API (`admin_api.rs`). Spec:
//! WESTBOUND_MULTIPLAYER_HANDOFF.md → "Moderation" (admin CLI: list reports, ban or unban
//! with duration, force-rename, and remove a run or leaderboard entry). Runbook:
//! docs/OPERATIONS.md.

use anyhow::{bail, Context};
use sqlx::SqlitePool;

use crate::accounts::{self, PERMANENT_BAN_UNTIL};
use crate::config::{BackupConfig, Config, LeaderboardsConfig};
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

/// A player by account id (`42`) or full name (`Road Runner#0042`, case-insensitive).
pub async fn resolve_player(pool: &SqlitePool, spec: &str) -> anyhow::Result<i64> {
    let spec = spec.trim();
    if let Ok(id) = spec.parse::<i64>() {
        return Ok(id);
    }
    let (name, tag) = spec
        .rsplit_once('#')
        .with_context(|| format!("player `{spec}`: give an account id or name#1234"))?;
    let tag: i64 = tag
        .parse()
        .with_context(|| format!("player `{spec}`: the tag after # must be a number"))?;
    sqlx::query_scalar::<_, i64>("SELECT id FROM accounts WHERE display_name = ? AND tag = ?")
        .bind(name.trim())
        .bind(tag)
        .fetch_optional(pool)
        .await?
        .with_context(|| format!("no player {spec}"))
}

/// One line of free text for `admin_log` (reasons, notes).
fn one_line(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Bans an account until `now + duration` (or permanently), with an optional reason
/// (kept in `admin_log`, shown by `admin player`).
pub async fn ban(
    pool: &SqlitePool,
    id: i64,
    duration: &str,
    reason: Option<&str>,
    now: i64,
) -> anyhow::Result<String> {
    let secs = parse_duration(duration)?;
    require_account(pool, id).await?;
    let until = secs.map_or(PERMANENT_BAN_UNTIL, |d| {
        now.saturating_add(d).min(PERMANENT_BAN_UNTIL)
    });
    accounts::set_ban(pool, id, Some(until)).await?;
    let mut detail = format!("until={until} duration={duration}");
    if let Some(r) = reason.map(one_line).filter(|r| !r.is_empty()) {
        detail.push_str(&format!(" reason={r}"));
    }
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

/// The pre-N10.3 form of a set-aside job (`failed` with `"unverifiable": true`), which a
/// worker from an older image may still write: counted and listed as `set_aside`.
/// NULL-safe, so `NOT (...)` keeps rows without the key.
const LEGACY_SET_ASIDE: &str = "status = 'failed' AND COALESCE(json_valid(result)
     AND json_extract(result, '$.unverifiable') = 1, 0) = 1";

/// Replay jobs (N8.1): `replays` lists the queue by status; `replay_requeue` puts a
/// `failed` job (or with `run_id` any job whose file is still there) back to `pending`
/// with its attempts reset. The server's worker picks it up within
/// `replays.poll_interval_secs`. N10.3: set-aside jobs (no verifier here has their build)
/// are `set_aside`, not `failed`, listed with their build and reason; those whose file
/// was purged are counted apart.
pub async fn replays(pool: &SqlitePool) -> anyhow::Result<String> {
    let rows = sqlx::query_as::<_, (String, i64)>(sqlx::AssertSqlSafe(format!(
        "SELECT CASE WHEN {LEGACY_SET_ASIDE} THEN 'set_aside' ELSE status END AS s, COUNT(*)
         FROM replays WHERE NOT (status = 'set_aside' AND file_deleted_at IS NOT NULL)
         GROUP BY s ORDER BY s"
    )))
    .fetch_all(pool)
    .await?;
    let mut out: Vec<String> = rows
        .into_iter()
        .map(|(status, n)| format!("{status} {n}"))
        .collect();
    let purged: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM replays WHERE status = 'set_aside' AND file_deleted_at IS NOT NULL",
    )
    .fetch_one(pool)
    .await?;
    if purged > 0 {
        out.push(format!("set_aside_purged {purged}"));
    }
    let failed = sqlx::query_as::<_, (i64, i64, Option<String>)>(sqlx::AssertSqlSafe(format!(
        "SELECT run_id, attempts, result FROM replays WHERE status = 'failed'
           AND NOT ({LEGACY_SET_ASIDE}) ORDER BY run_id LIMIT {LIST_LIMIT}"
    )))
    .fetch_all(pool)
    .await?;
    for (run_id, attempts, result) in failed {
        out.push(format!(
            "failed run {run_id} after {attempts} attempts: {}",
            result.unwrap_or_default()
        ));
    }
    let parked = sqlx::query_as::<_, (i64, i64, Option<String>)>(sqlx::AssertSqlSafe(format!(
        "SELECT run_id, created_at, result FROM replays
         WHERE file_deleted_at IS NULL AND (status = 'set_aside' OR ({LEGACY_SET_ASIDE}))
         ORDER BY created_at, run_id LIMIT {LIST_LIMIT}"
    )))
    .fetch_all(pool)
    .await?;
    for (run_id, created_at, result) in parked {
        let r: serde_json::Value = result
            .as_deref()
            .and_then(|t| serde_json::from_str(t).ok())
            .unwrap_or_default();
        out.push(format!(
            "set aside run {run_id} (build {}, uploaded {created_at}): {}",
            r["build"],
            r["error"].as_str().unwrap_or("")
        ));
    }
    if out.is_empty() {
        return Ok("no replays".into());
    }
    Ok(out.join("\n"))
}

/// Jobs listed per kind by `admin replays`.
const LIST_LIMIT: i64 = 20;

/// N10.3: set-aside jobs uploaded more than `older_than_secs` ago lose their replay file;
/// their runs stay "verifying" (the row stays `set_aside`, marked purged, so no worker
/// start requeues it). Logged to the admin log.
pub async fn replay_purge_set_aside(
    pool: &SqlitePool,
    older_than_secs: i64,
    now: i64,
) -> anyhow::Result<String> {
    let n = crate::replays::retention::purge_set_aside(pool, now - older_than_secs, now).await?;
    crate::db::admin_log(
        pool,
        ACTOR,
        "replay_purge_set_aside",
        "",
        &format!("older_than_secs={older_than_secs} jobs={n}"),
    )
    .await?;
    Ok(format!(
        "{n} set-aside replay job(s) purged: files deleted, their runs stay verifying"
    ))
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

/// Everything moderation needs about one player, as `key value` lines.
pub async fn player(pool: &SqlitePool, id: i64, now: i64) -> anyhow::Result<String> {
    type Row = (
        i64,
        String,
        i64,
        i64,
        Option<i64>,
        Option<i64>,
        Option<i64>,
        bool,
        bool,
    );
    let row: Option<Row> = sqlx::query_as(
        "SELECT id, display_name, tag, created_at, last_seen, banned_until, name_changed_at,
                apple_sub IS NOT NULL, google_sub IS NOT NULL
         FROM accounts WHERE id = ?",
    )
    .bind(id)
    .fetch_optional(pool)
    .await?;
    let Some((id, name, tag, created, seen, banned_until, renamed, apple, google)) = row else {
        bail!("no account {id}");
    };
    let count = |sql: &'static str| sqlx::query_scalar::<_, i64>(sql).bind(id).fetch_one(pool);
    let runs = count("SELECT COUNT(*) FROM runs WHERE account_id = ?").await?;
    let reports_against = count("SELECT COUNT(*) FROM reports WHERE target_id = ?").await?;
    let reports_open =
        count("SELECT COUNT(*) FROM reports WHERE target_id = ? AND handled = 0").await?;
    let reports_by = count("SELECT COUNT(*) FROM reports WHERE reporter_id = ?").await?;
    let friends = count(
        "SELECT COUNT(*) FROM friends WHERE (account_a = ?1 OR account_b = ?1) AND status = 'accepted'",
    )
    .await?;
    let crew: Option<(i64, String, String, String)> = sqlx::query_as(
        "SELECT c.id, c.name, c.tag, m.role FROM crew_members m JOIN crews c ON c.id = m.crew_id
         WHERE m.account_id = ?",
    )
    .bind(id)
    .fetch_optional(pool)
    .await?;
    let last_ban: Option<(String, i64)> = sqlx::query_as(
        "SELECT detail, created_at FROM admin_log WHERE action = 'ban' AND target = ?
         ORDER BY id DESC LIMIT 1",
    )
    .bind(id.to_string())
    .fetch_optional(pool)
    .await?;
    let entries: Vec<(String, String, i64)> = sqlx::query_as(
        "SELECT board, period_key, score FROM leaderboard_entries WHERE account_id = ?
         ORDER BY board, period_key DESC LIMIT ?",
    )
    .bind(id)
    .bind(PLAYER_ENTRIES_SHOWN)
    .fetch_all(pool)
    .await?;
    let opt = |v: Option<i64>| v.map_or("-".to_string(), |t| t.to_string());
    let ban = match banned_until {
        Some(u) if u >= PERMANENT_BAN_UNTIL => "permanent".to_string(),
        Some(u) if u > now => format!("until {u} ({} s left)", u - now),
        Some(u) => format!("expired {u}"),
        None => "no".to_string(),
    };
    let mut out = vec![
        format!("account {id}"),
        format!(
            "name {}",
            names::full_name(&name, u16::try_from(tag).unwrap_or(0))
        ),
        format!("created {created}"),
        format!("last_seen {}", opt(seen)),
        format!("renamed {}", opt(renamed)),
        format!("linked apple={apple} google={google}"),
        format!("banned {ban}"),
    ];
    if let Some((detail, at)) = last_ban {
        out.push(format!("last_ban {at} {detail}"));
    }
    out.push(match crew {
        Some((cid, cname, ctag, role)) => format!("crew {cid} {cname} [{ctag}] {role}"),
        None => "crew -".to_string(),
    });
    out.push(format!("friends {friends}"));
    out.push(format!("runs {runs}"));
    out.push(format!(
        "reports against={reports_against} (unhandled {reports_open}) by={reports_by}"
    ));
    for (board, period, score) in entries {
        out.push(format!("entry {board}/{period} {score}"));
    }
    Ok(out.join("\n"))
}

/// Leaderboard entries `admin player` lists.
const PLAYER_ENTRIES_SHOWN: i64 = 20;

/// Deletes a player and all of their data, as `DELETE /api/v1/account` does (actor `cli`).
pub async fn delete_player(
    pool: &SqlitePool,
    cfg: &LeaderboardsConfig,
    id: i64,
    now: i64,
) -> anyhow::Result<String> {
    let before = require_account(pool, id).await?;
    let r = accounts::delete(pool, cfg, id, ACTOR, now).await?;
    if r.accounts == 0 {
        bail!("no account {id}");
    }
    Ok(format!(
        "account {id} ({}) deleted: runs={} entries={} replays={} friends={} crew_memberships={}",
        names::full_name(&before.display_name, before.tag),
        r.runs,
        r.leaderboard_entries,
        r.replays,
        r.social.friends,
        r.social.crew_memberships
    ))
}

/// Rebuilds a board period from the runs: every player's entry from their best eligible
/// run (`leaderboards::recompute`), or on `loop_crew` every crew's sum. One transaction.
pub async fn recompute_board(
    pool: &SqlitePool,
    cfg: &LeaderboardsConfig,
    board: &str,
    period: &str,
    now: i64,
) -> anyhow::Result<String> {
    let b = Board::parse(board).with_context(|| {
        format!("board `{board}`: expected loop, loop_crew, journey, daily or distance")
    })?;
    let p = b
        .parse_period(period)
        .with_context(|| format!("period `{period}` is not one board `{board}` keeps"))?;
    let mut tx = pool.begin_with("BEGIN IMMEDIATE").await?;
    let before: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM leaderboard_entries WHERE board = ? AND period_key = ?",
    )
    .bind(b.id())
    .bind(&p.key)
    .fetch_one(&mut *tx)
    .await?;
    let mut changed = 0usize;
    if b.is_crew() {
        let crews: Vec<i64> = sqlx::query_scalar(
            "SELECT id FROM crews UNION SELECT subject_id FROM leaderboard_entries
             WHERE board = ? AND period_key = ?",
        )
        .bind(b.id())
        .bind(&p.key)
        .fetch_all(&mut *tx)
        .await?;
        for crew in crews {
            if leaderboards::recompute_crew(&mut tx, cfg, crew, &p, now).await? {
                changed += 1;
            }
        }
    } else {
        let players: Vec<i64> = sqlx::query_scalar(
            "SELECT DISTINCT account_id FROM runs UNION SELECT account_id FROM leaderboard_entries
             WHERE board = ? AND period_key = ? AND account_id IS NOT NULL",
        )
        .bind(b.id())
        .bind(&p.key)
        .fetch_all(&mut *tx)
        .await?;
        for account in players {
            if leaderboards::recompute(&mut tx, b, &p, account, cfg.show_pending).await? {
                changed += 1;
            }
        }
    }
    let after: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM leaderboard_entries WHERE board = ? AND period_key = ?",
    )
    .bind(b.id())
    .bind(&p.key)
    .fetch_one(&mut *tx)
    .await?;
    let target = format!("{board}/{}", p.key);
    crate::db::admin_log(
        &mut *tx,
        ACTOR,
        "recompute",
        &target,
        &format!("entries={before}->{after} written={changed}"),
    )
    .await?;
    tx.commit().await?;
    Ok(format!(
        "{target} recomputed: {before} -> {after} entries ({changed} written)"
    ))
}

/// Database-side stats, as `key value` lines.
pub async fn db_stats(pool: &SqlitePool, now: i64) -> anyhow::Result<String> {
    let day = now - crate::clock::SECS_PER_DAY;
    let week = now - 7 * crate::clock::SECS_PER_DAY;
    let scalar = |sql: &'static str| sqlx::query_scalar::<_, i64>(sql);
    let mut out = Vec::new();
    for (key, sql) in [
        ("accounts", "SELECT COUNT(*) FROM accounts"),
        ("runs", "SELECT COUNT(*) FROM runs"),
        (
            "leaderboard_entries",
            "SELECT COUNT(*) FROM leaderboard_entries",
        ),
        ("crews", "SELECT COUNT(*) FROM crews"),
        (
            "friendships",
            "SELECT COUNT(*) FROM friends WHERE status = 'accepted'",
        ),
        (
            "reports_unhandled",
            "SELECT COUNT(*) FROM reports WHERE handled = 0",
        ),
    ] {
        let n = scalar(sql).fetch_one(pool).await?;
        out.push(format!("{key} {n}"));
    }
    for (key, sql, since) in [
        (
            "accounts_new_24h",
            "SELECT COUNT(*) FROM accounts WHERE created_at >= ?",
            day,
        ),
        (
            "accounts_seen_24h",
            "SELECT COUNT(*) FROM accounts WHERE last_seen >= ?",
            day,
        ),
        (
            "accounts_seen_7d",
            "SELECT COUNT(*) FROM accounts WHERE last_seen >= ?",
            week,
        ),
        (
            "accounts_banned",
            "SELECT COUNT(*) FROM accounts WHERE banned_until > ?",
            now,
        ),
        (
            "runs_24h",
            "SELECT COUNT(*) FROM runs WHERE created_at >= ?",
            day,
        ),
        (
            "reports_24h",
            "SELECT COUNT(*) FROM reports WHERE created_at >= ?",
            day,
        ),
    ] {
        let n = scalar(sql).bind(since).fetch_one(pool).await?;
        out.push(format!("{key} {n}"));
    }
    let modes: Vec<(String, i64)> = sqlx::query_as(
        "SELECT mode, COUNT(*) FROM runs WHERE created_at >= ? GROUP BY mode ORDER BY mode",
    )
    .bind(day)
    .fetch_all(pool)
    .await?;
    for (mode, n) in modes {
        out.push(format!("runs_24h_{mode} {n}"));
    }
    let queue: Vec<(String, i64)> =
        sqlx::query_as("SELECT status, COUNT(*) FROM replays GROUP BY status ORDER BY status")
            .fetch_all(pool)
            .await?;
    for (status, n) in queue {
        out.push(format!("replays_{status} {n}"));
    }
    let size: i64 =
        scalar("SELECT page_count * page_size FROM pragma_page_count(), pragma_page_size()")
            .fetch_one(pool)
            .await?;
    out.push(format!("db_bytes {size}"));
    let last_backup: Option<(String, i64)> = sqlx::query_as(
        "SELECT target, created_at FROM admin_log WHERE action = 'backup' ORDER BY id DESC LIMIT 1",
    )
    .fetch_optional(pool)
    .await?;
    out.push(match last_backup {
        Some((file, at)) => format!("last_backup {at} {file}"),
        None => "last_backup -".to_string(),
    });
    Ok(out.join("\n"))
}

/// The admin log, newest first.
pub async fn log(pool: &SqlitePool, limit: i64) -> anyhow::Result<String> {
    let rows: Vec<(i64, i64, String, String, String, String)> = sqlx::query_as(
        "SELECT id, created_at, actor, action, target, detail FROM admin_log
         ORDER BY id DESC LIMIT ?",
    )
    .bind(limit.max(1))
    .fetch_all(pool)
    .await?;
    if rows.is_empty() {
        return Ok("admin log is empty".into());
    }
    Ok(rows
        .into_iter()
        .map(|(id, at, actor, action, target, detail)| {
            format!("#{id} {at} {actor} {action} {target} {detail}")
                .trim_end()
                .to_string()
        })
        .collect::<Vec<_>>()
        .join("\n"))
}

/// The dated backups in `backup.dir`, oldest first, with sizes and ages; N10.3: how many
/// are kept, the newest one's age against `backup.max_age_hours` (`ok` / `STALE`), and
/// the volume's free space.
pub fn backups(cfg: &BackupConfig, now: i64) -> anyhow::Result<String> {
    let dir = &cfg.dir;
    let s = crate::backup::status(dir, now, cfg.max_age_hours)
        .with_context(|| format!("reading {}", dir.display()))?;
    let mut out: Vec<String> = s
        .files
        .iter()
        .map(|f| {
            format!(
                "{} {} bytes, written {} ({} h ago)",
                f.name,
                f.bytes,
                f.modified_unix,
                (now - f.modified_unix).max(0) / SECS_PER_HOUR
            )
        })
        .collect();
    if s.files.is_empty() {
        out.push(if dir.exists() {
            format!("no backups in {}", dir.display())
        } else {
            format!("no backups in {} (it does not exist yet)", dir.display())
        });
    }
    out.push(format!(
        "dated backups: {} (at most {} kept), {} bytes",
        s.files.len(),
        cfg.retention_days,
        s.total_bytes
    ));
    let verdict = if s.stale { "STALE" } else { "ok" };
    out.push(match (s.newest(), s.newest_age_secs) {
        (Some(f), Some(age)) => format!(
            "newest: {} {} h old: {verdict} (stale after {} h)",
            f.name,
            age / SECS_PER_HOUR,
            cfg.max_age_hours
        ),
        _ => format!("newest: none: {verdict}"),
    });
    if let Some(v) = crate::housekeeping::volume_space(dir) {
        out.push(format!(
            "volume: {} of {} bytes free",
            v.free_bytes, v.total_bytes
        ));
    }
    Ok(out.join("\n"))
}

/// N10.3: the disk numbers for `admin stats` (`key value` lines, like the rest).
pub fn disk_stats(cfg: &Config, now: i64) -> String {
    let u = crate::housekeeping::disk_usage(cfg);
    let opt = |v: Option<u64>| v.map_or("-".to_string(), |v| v.to_string());
    let mut out = vec![
        format!("disk_data_dir {}", u.data_dir),
        format!("disk_free_bytes {}", opt(u.free_bytes)),
        format!("disk_total_bytes {}", opt(u.total_bytes)),
        format!("disk_min_free_bytes {}", u.min_free_bytes),
        format!("disk_low {}", u.low),
        format!("disk_db_bytes {}", u.db_bytes),
        format!("disk_wal_bytes {}", u.wal_bytes),
        format!("disk_replays_bytes {}", u.replays_bytes),
        format!("disk_replays_files {}", u.replays_files),
        format!("disk_backups_bytes {}", u.backups_bytes),
        format!("disk_other_bytes {}", u.other_bytes),
        format!("disk_data_bytes {}", u.data_bytes),
    ];
    if let Ok(s) = crate::backup::status(&cfg.backup.dir, now, cfg.backup.max_age_hours) {
        out.push(format!("backup_files {}", s.files.len()));
        out.push(format!(
            "backup_newest {}",
            s.newest().map_or("-", |f| f.name.as_str())
        ));
        out.push(format!(
            "backup_newest_age_secs {}",
            s.newest_age_secs.map_or("-".to_string(), |a| a.to_string())
        ));
        out.push(format!("backup_stale {}", s.stale));
    }
    out.join("\n")
}

const SECS_PER_HOUR: i64 = 3_600;

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
