//! westbound-server: HTTP API, realtime gateway, lobby, rooms, DB, admin CLI. WP N0.1.
//! Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Server tech stack" (clap: the same binary
//! runs admin commands). Runbook: docs/SERVER.md.

use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

use anyhow::Context;
use clap::{Parser, Subcommand};
use westbound_server::admin_client::AdminClient;
use westbound_server::{
    admin, admin_api, backup, clock, config, db, healthcheck, shutdown, telemetry, Config, Server,
};

/// Seconds the `healthcheck` command waits for an answer.
const HEALTHCHECK_TIMEOUT: Duration = Duration::from_secs(3);
/// How long `restore` waits for a running server to answer before going ahead.
const RESTORE_PROBE_TIMEOUT: Duration = Duration::from_secs(1);

#[derive(Parser)]
#[command(name = "westbound-server", version = long_version(), about = "Westbound Online server")]
struct Cli {
    /// TOML config file. Defaults apply for anything it leaves out; `WB_<SECTION>__<KEY>`
    /// env vars override both.
    #[arg(long, short, global = true, env = config::ENV_CONFIG_PATH)]
    config: Option<PathBuf>,
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Run the server (default).
    Serve,
    /// Apply pending database migrations and exit.
    Migrate,
    /// Validate the config and print the effective values (secrets redacted).
    CheckConfig,
    /// Write a consistent online backup of the live database to PATH (`VACUUM INTO`).
    Backup { path: PathBuf },
    /// Check a backup file: integrity check and the migrations it holds.
    VerifyBackup { path: PathBuf },
    /// Replace the database with BACKUP (stop the server first; the current file is kept as
    /// `<db>.before-restore-<unix secs>`). Newer migrations are applied.
    Restore {
        backup: PathBuf,
        /// Go ahead even though a server answers on `server.bind`.
        #[arg(long)]
        force: bool,
    },
    /// Probe `/api/v1/health` on localhost; exit 0 when healthy (Docker HEALTHCHECK).
    Healthcheck,
    /// Run the replay verification queue alone, against the same database (a sidecar next
    /// to `serve` with `replays.worker_enabled = false`; docs/SERVER.md → Replays).
    VerifyWorker,
    /// Admin commands: moderation and board fixes on the database (each change is logged to
    /// admin_log); live rooms, notices and kicks through the running server's admin API.
    Admin {
        #[command(subcommand)]
        command: AdminCommand,
    },
}

#[derive(Subcommand)]
enum AdminCommand {
    /// Everything about one player: PLAYER is an account id or name#1234.
    Player { player: String },
    /// Ban PLAYER for DURATION (`30m`, `12h`, `7d`, `2w`) or `perm`. Their live session ends
    /// now when the admin API is on (else within `gateway.ban_recheck_ms`).
    Ban {
        player: String,
        duration: String,
        /// Why (kept in the admin log, shown by `admin player`).
        #[arg(long)]
        reason: Option<String>,
    },
    /// Lift PLAYER's ban.
    Unban { player: String },
    /// Force-rename PLAYER (name rules and filter apply; a new #tag if needed).
    Rename { player: String, name: String },
    /// Delete PLAYER and all their data, as the in-game account deletion does.
    DeletePlayer {
        player: String,
        /// Required: the deletion cannot be undone.
        #[arg(long)]
        yes: bool,
    },
    /// Delete a run (and its replay); the entries it held fall back to the player's next
    /// best run.
    RemoveRun { run_id: i64 },
    /// Delete one leaderboard entry: BOARD (loop, loop_crew, journey, daily, distance),
    /// PERIOD (YYYY-MM, YYYY-Www, YYYY-MM-DD or all) and the account (crew on loop_crew).
    RemoveEntry {
        board: String,
        period: String,
        account_id: i64,
    },
    /// Rebuild BOARD's PERIOD from the runs (every player's best eligible run; crews' sums).
    Recompute { board: String, period: String },
    /// The replay verification queue: jobs per status, and the failed ones with why.
    Replays,
    /// Put failed replay jobs (or one run's job) back in the queue with fresh attempts.
    ReplayRequeue { run_id: Option<i64> },
    /// List player reports, newest first.
    Reports {
        /// Only reports not handled yet.
        #[arg(long)]
        unhandled: bool,
        /// Most reports listed.
        #[arg(long, default_value_t = 50)]
        limit: i64,
    },
    /// Mark a report handled (resolved).
    #[command(alias = "report-resolve")]
    ReportHandle { report_id: i64 },
    /// Force-rename a crew (name rules and filter apply) and/or change its tag.
    CrewRename {
        crew_id: i64,
        /// The new name (leave out to change only the tag).
        name: Option<String>,
        /// A new 2-4 character tag.
        #[arg(long)]
        tag: Option<String>,
    },
    /// Disband a crew (its members are released; its Loop crew entries are removed).
    CrewDisband { crew_id: i64 },
    /// Live rooms on the running server (admin API).
    Rooms,
    /// Close a live room (code or id): runs end with their banked score, the players get
    /// MESSAGE and go back to the hub (admin API).
    RoomClose {
        room: String,
        #[arg(long, short)]
        message: Option<String>,
    },
    /// Send a notice to every connected player (admin API).
    Notice {
        text: String,
        /// info, maintenance or restart.
        #[arg(long, default_value = "info")]
        kind: String,
        /// Seconds until the event (maintenance, restart).
        #[arg(long, default_value_t = 0)]
        seconds: u16,
    },
    /// End PLAYER's live session now (admin API); they can sign in again unless banned.
    Kick { player: String },
    /// Database stats, plus the live ones when the server answers.
    Stats,
    /// The admin log, newest first.
    Log {
        #[arg(long, default_value_t = 50)]
        limit: i64,
    },
    /// The dated backups in `backup.dir`.
    Backups,
}

fn long_version() -> &'static str {
    // Leaked once at startup: clap wants a 'static str.
    Box::leak(
        format!(
            "{} ({})",
            westbound_server::VERSION,
            westbound_server::BUILD
        )
        .into_boxed_str(),
    )
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let cfg = match Config::load(cli.config.as_deref(), std::env::vars()) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("westbound-server: {e:#}");
            return ExitCode::from(2);
        }
    };
    let command = cli.command.unwrap_or(Command::Serve);
    let result = match command {
        Command::CheckConfig => {
            print!("{}", cfg.to_redacted_toml());
            eprintln!("config ok");
            Ok(())
        }
        Command::Healthcheck => current_thread().and_then(|rt| {
            rt.block_on(async {
                let h = healthcheck::check(cfg.bind_addr(), HEALTHCHECK_TIMEOUT).await?;
                println!("ok {} ({}) db={}", h.version, h.build, h.db);
                Ok(())
            })
        }),
        Command::Migrate => {
            telemetry::init(&cfg.log);
            current_thread().and_then(|rt| rt.block_on(migrate(&cfg)))
        }
        Command::Backup { path } => {
            telemetry::init(&cfg.log);
            current_thread().and_then(|rt| rt.block_on(backup_cmd(&cfg, &path)))
        }
        Command::VerifyBackup { path } => current_thread().and_then(|rt| {
            rt.block_on(async {
                let n = backup::verify(&path).await?;
                println!("ok {} ({n} migrations)", path.display());
                Ok(())
            })
        }),
        Command::Restore {
            backup: backup_path,
            force,
        } => {
            telemetry::init(&cfg.log);
            current_thread().and_then(|rt| rt.block_on(restore_cmd(&cfg, &backup_path, force)))
        }
        Command::Admin { command } => {
            telemetry::init(&cfg.log);
            current_thread().and_then(|rt| rt.block_on(admin_cmd(&cfg, command)))
        }
        Command::VerifyWorker => {
            telemetry::init(&cfg.log);
            current_thread().and_then(|rt| rt.block_on(verify_worker(cfg)))
        }
        Command::Serve => {
            telemetry::init(&cfg.log);
            tokio::runtime::Builder::new_multi_thread()
                .worker_threads(cfg.server.worker_threads)
                .enable_all()
                .build()
                .context("building the tokio runtime")
                .and_then(|rt| rt.block_on(serve(cfg)))
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("westbound-server: {e:#}");
            ExitCode::FAILURE
        }
    }
}

fn current_thread() -> anyhow::Result<tokio::runtime::Runtime> {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("building the tokio runtime")
}

async fn migrate(cfg: &Config) -> anyhow::Result<()> {
    let pool = db::connect(&cfg.db).await?;
    db::migrate(&pool).await?;
    let applied = db::MIGRATOR.iter().count();
    tracing::info!(path = %cfg.db.path.display(), migrations = applied, "migrations applied");
    db::close(&pool).await;
    Ok(())
}

async fn backup_cmd(cfg: &Config, path: &std::path::Path) -> anyhow::Result<()> {
    let pool = db::connect(&cfg.db).await?;
    db::backup_to(&pool, path).await?;
    if cfg.backup.verify {
        backup::verify(path).await?;
    }
    db::admin_log(&pool, "cli", "backup", &path.display().to_string(), "").await?;
    tracing::info!(path = %path.display(), "backup written");
    db::close(&pool).await;
    Ok(())
}

async fn admin_cmd(cfg: &Config, command: AdminCommand) -> anyhow::Result<()> {
    // The live commands need only the admin API.
    let live = match &command {
        AdminCommand::Rooms => Some(admin_rooms(cfg).await),
        AdminCommand::RoomClose { room, message } => {
            let api = AdminClient::from_config(cfg)?;
            let body = serde_json::json!({ "message": message.clone().unwrap_or_default() });
            let path = format!("{}/rooms/{}/close", admin_api::PREFIX, room.trim());
            Some(api.post::<serde_json::Value>(&path, &body).await.map(|v| {
                format!(
                    "room {} ({}) closed",
                    v["code"].as_str().unwrap_or(room),
                    v["room_id"]
                )
            }))
        }
        AdminCommand::Notice {
            text,
            kind,
            seconds,
        } => {
            let api = AdminClient::from_config(cfg)?;
            let body = serde_json::json!({ "kind": kind, "seconds": seconds, "text": text });
            let path = format!("{}/notice", admin_api::PREFIX);
            Some(
                api.post::<serde_json::Value>(&path, &body)
                    .await
                    .map(|v| format!("notice sent to {} session(s)", v["sessions"])),
            )
        }
        _ => None,
    };
    if let Some(r) = live {
        println!("{}", r?);
        return Ok(());
    }
    let pool = db::connect(&cfg.db).await?;
    let now = clock::unix_now_secs();
    let result = admin_db_cmd(cfg, &pool, command, now).await;
    db::close(&pool).await;
    println!("{}", result?);
    Ok(())
}

/// `admin rooms`: one line per live room.
async fn admin_rooms(cfg: &Config) -> anyhow::Result<String> {
    let api = AdminClient::from_config(cfg)?;
    let rooms: Vec<serde_json::Value> = api.get(&format!("{}/rooms", admin_api::PREFIX)).await?;
    if rooms.is_empty() {
        return Ok("no live rooms".into());
    }
    Ok(rooms
        .iter()
        .map(|r| {
            format!(
                "{} {} {} {}/{} {}{} accounts={}",
                r["room_id"],
                r["code"].as_str().unwrap_or("?"),
                r["visibility"].as_str().unwrap_or("?"),
                r["players"],
                r["max_players"],
                r["density"].as_str().unwrap_or("?"),
                if r["night"].as_bool().unwrap_or(false) {
                    " night"
                } else {
                    ""
                },
                r["accounts"]
            )
        })
        .collect::<Vec<_>>()
        .join("\n"))
}

/// Ends the account's live session through the admin API, if it is on; a note for the
/// command's output.
async fn kick_now(cfg: &Config, account: i64, reason: &str) -> String {
    let Ok(api) = AdminClient::from_config(cfg) else {
        return "live session (if any) ends within the ban re-check (admin API off)".into();
    };
    let path = format!("{}/kick/{account}", admin_api::PREFIX);
    match api
        .post::<serde_json::Value>(&path, &serde_json::json!({ "reason": reason }))
        .await
    {
        Ok(v) if v["kicked"].as_bool() == Some(true) => "live session ended".into(),
        Ok(_) => "not connected".into(),
        Err(e) => format!("live kick failed ({e:#}); the session ends within the ban re-check"),
    }
}

/// After a board change from the CLI: the running server drops its cached board tops now
/// (admin API on), else they catch up within `leaderboards.cache_ttl_secs`.
async fn invalidate_boards(cfg: &Config) {
    if let Ok(api) = AdminClient::from_config(cfg) {
        let path = format!("{}/boards/invalidate", admin_api::PREFIX);
        if let Err(e) = api
            .post::<serde_json::Value>(&path, &serde_json::json!({}))
            .await
        {
            eprintln!(
                "note: cached boards not invalidated ({e:#}); they catch up within the cache TTL"
            );
        }
    }
}

async fn admin_db_cmd(
    cfg: &Config,
    pool: &sqlx::SqlitePool,
    command: AdminCommand,
    now: i64,
) -> anyhow::Result<String> {
    let player = |spec: String| async move { admin::resolve_player(pool, &spec).await };
    match command {
        AdminCommand::Player { player: p } => admin::player(pool, player(p).await?, now).await,
        AdminCommand::Ban {
            player: p,
            duration,
            reason,
        } => {
            let id = player(p).await?;
            let out = admin::ban(pool, id, &duration, reason.as_deref(), now).await?;
            Ok(format!("{out}; {}", kick_now(cfg, id, "banned").await))
        }
        AdminCommand::Unban { player: p } => admin::unban(pool, player(p).await?).await,
        AdminCommand::Rename { player: p, name } => {
            admin::rename(pool, player(p).await?, &name, now).await
        }
        AdminCommand::DeletePlayer { player: p, yes } => {
            let id = player(p).await?;
            if !yes {
                anyhow::bail!("deleting account {id} cannot be undone: add --yes");
            }
            let out = admin::delete_player(pool, &cfg.leaderboards, id, now).await?;
            invalidate_boards(cfg).await;
            Ok(format!("{out}; {}", kick_now(cfg, id, "revoked").await))
        }
        AdminCommand::Kick { player: p } => {
            let id = player(p).await?;
            AdminClient::from_config(cfg)?;
            Ok(format!(
                "account {id}: {}",
                kick_now(cfg, id, "closed").await
            ))
        }
        AdminCommand::RemoveRun { run_id } => {
            let out = admin::remove_run(pool, &cfg.leaderboards, run_id).await?;
            invalidate_boards(cfg).await;
            Ok(out)
        }
        AdminCommand::Replays => admin::replays(pool).await,
        AdminCommand::ReplayRequeue { run_id } => admin::replay_requeue(pool, run_id).await,
        AdminCommand::RemoveEntry {
            board,
            period,
            account_id,
        } => {
            let out = admin::remove_entry(pool, &board, &period, account_id).await?;
            invalidate_boards(cfg).await;
            Ok(out)
        }
        AdminCommand::Recompute { board, period } => {
            let out = admin::recompute_board(pool, &cfg.leaderboards, &board, &period, now).await?;
            invalidate_boards(cfg).await;
            Ok(out)
        }
        AdminCommand::Reports { unhandled, limit } => admin::reports(pool, unhandled, limit).await,
        AdminCommand::ReportHandle { report_id } => {
            admin::report_handle(pool, report_id, now).await
        }
        AdminCommand::CrewRename { crew_id, name, tag } => {
            admin::crew_rename(pool, crew_id, name.as_deref(), tag.as_deref()).await
        }
        AdminCommand::CrewDisband { crew_id } => {
            let out = admin::crew_disband(pool, crew_id).await?;
            invalidate_boards(cfg).await;
            Ok(out)
        }
        AdminCommand::Stats => {
            let mut out = admin::db_stats(pool, now).await?;
            match AdminClient::from_config(cfg) {
                Ok(api) => match api
                    .get::<admin_api::LiveStats>(&format!("{}/stats", admin_api::PREFIX))
                    .await
                {
                    Ok(s) => {
                        out.push_str(&format!(
                            "\nlive_version {} ({})\nlive_uptime_secs {}\nlive_sessions {}\n\
                             live_connections {}\nlive_rooms {} (public {}, private {})\n\
                             live_seats {}\nlive_draining {}",
                            s.version,
                            s.build,
                            s.uptime_secs,
                            s.sessions,
                            s.connections,
                            s.rooms,
                            s.public_rooms,
                            s.private_rooms,
                            s.seats,
                            s.draining
                        ));
                    }
                    Err(e) => out.push_str(&format!("\nlive unavailable: {e:#}")),
                },
                Err(_) => out.push_str("\nlive unavailable: admin API off"),
            }
            Ok(out)
        }
        AdminCommand::Log { limit } => admin::log(pool, limit).await,
        AdminCommand::Backups => admin::backups(&cfg.backup.dir),
        AdminCommand::Rooms | AdminCommand::RoomClose { .. } | AdminCommand::Notice { .. } => {
            unreachable!("handled by admin_cmd")
        }
    }
}

/// `restore`: refuses while a server answers on `server.bind` (unless `--force`), then
/// `backup::restore`.
async fn restore_cmd(
    cfg: &Config,
    backup_path: &std::path::Path,
    force: bool,
) -> anyhow::Result<()> {
    let probe = healthcheck::probe_addr(cfg.bind_addr());
    if !force
        && healthcheck::get(probe, healthcheck::HEALTH_PATH, RESTORE_PROBE_TIMEOUT)
            .await
            .is_ok()
    {
        anyhow::bail!(
            "a server answers on {probe}: stop it first (restore replaces its database), or pass --force"
        );
    }
    let r = backup::restore(&cfg.db, backup_path, clock::unix_now_secs()).await?;
    println!(
        "restored {} into {} (migrations {} -> {}); previous database: {}",
        backup_path.display(),
        cfg.db.path.display(),
        r.migrations_in_backup,
        r.migrations_now,
        r.previous
            .map_or("none".to_string(), |p| p.display().to_string())
    );
    Ok(())
}

/// The replay queue worker on its own (N8.1): one verifier process at a time until
/// SIGTERM / SIGINT.
async fn verify_worker(cfg: Config) -> anyhow::Result<()> {
    if cfg.replays.verifier_command.is_empty() {
        anyhow::bail!("replays.verifier_command is empty: nothing to run the jobs with");
    }
    let pool = db::connect(&cfg.db).await?;
    let clock: std::sync::Arc<dyn clock::Clock> = std::sync::Arc::new(clock::SystemClock);
    let boards = std::sync::Arc::new(westbound_server::leaderboards::Leaderboards::new(
        pool.clone(),
        cfg.leaderboards.clone(),
        clock.clone(),
    ));
    let worker = westbound_server::replays::worker::Worker {
        db: pool.clone(),
        boards,
        cfg: cfg.replays.clone(),
        clock,
        wake: std::sync::Arc::new(tokio::sync::Notify::new()),
    };
    let stop = tokio_util::sync::CancellationToken::new();
    let on_signal = stop.clone();
    tokio::spawn(async move {
        shutdown::signal().await;
        on_signal.cancel();
    });
    worker.run(stop).await;
    db::close(&pool).await;
    tracing::info!("verify-worker stopped");
    Ok(())
}

async fn serve(cfg: Config) -> anyhow::Result<()> {
    let pool = db::connect(&cfg.db).await?;
    if cfg.db.migrate_on_start {
        db::migrate(&pool).await?;
    }
    let server = Server::bind(cfg, pool.clone()).await?;
    let state = server.state().clone();
    let cfg = state.config.clone();
    if cfg.backup.enabled {
        tokio::spawn(backup::nightly(
            pool.clone(),
            cfg.backup.clone(),
            state.metrics.clone(),
            state.shutdown.clone(),
        ));
    }
    tokio::spawn(shutdown::watch(state));
    let result = server.run().await;
    db::close(&pool).await;
    tracing::info!("database closed");
    result
}
