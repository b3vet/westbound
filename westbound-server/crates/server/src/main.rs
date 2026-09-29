//! westbound-server: HTTP API, realtime gateway, lobby, rooms, DB, admin CLI. WP N0.1.
//! Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Server tech stack" (clap: the same binary
//! runs admin commands). Runbook: docs/SERVER.md.

use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

use anyhow::Context;
use clap::{Parser, Subcommand};
use westbound_server::{
    admin, backup, clock, config, db, healthcheck, shutdown, telemetry, Config, Server,
};

/// Seconds the `healthcheck` command waits for an answer.
const HEALTHCHECK_TIMEOUT: Duration = Duration::from_secs(3);

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
    /// Probe `/api/v1/health` on localhost; exit 0 when healthy (Docker HEALTHCHECK).
    Healthcheck,
    /// Run the replay verification queue alone, against the same database (a sidecar next
    /// to `serve` with `replays.worker_enabled = false`; docs/SERVER.md → Replays).
    VerifyWorker,
    /// Moderation commands on the live database (each one is logged to admin_log).
    Admin {
        #[command(subcommand)]
        command: AdminCommand,
    },
}

#[derive(Subcommand)]
enum AdminCommand {
    /// Ban an account for DURATION (`30m`, `12h`, `7d`, `2w`) or `perm`.
    Ban { account_id: i64, duration: String },
    /// Lift an account's ban.
    Unban { account_id: i64 },
    /// Force-rename an account (name rules and filter apply; a new #tag if needed).
    Rename { account_id: i64, name: String },
    /// Delete a run (and its replay); the entries it held fall back to the player's next
    /// best run.
    RemoveRun { run_id: i64 },
    /// The replay verification queue: jobs per status, and the failed ones with why.
    Replays,
    /// Put failed replay jobs (or one run's job) back in the queue with fresh attempts.
    ReplayRequeue { run_id: Option<i64> },
    /// Delete one leaderboard entry: BOARD (loop, loop_crew, journey, daily, distance),
    /// PERIOD (YYYY-MM, YYYY-Www, YYYY-MM-DD or all) and the account (crew on loop_crew).
    RemoveEntry {
        board: String,
        period: String,
        account_id: i64,
    },
    /// List player reports, newest first.
    Reports {
        /// Only reports not handled yet.
        #[arg(long)]
        unhandled: bool,
        /// Most reports listed.
        #[arg(long, default_value_t = 50)]
        limit: i64,
    },
    /// Mark a report handled.
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
    db::admin_log(&pool, "cli", "backup", &path.display().to_string(), "").await?;
    tracing::info!(path = %path.display(), "backup written");
    db::close(&pool).await;
    Ok(())
}

async fn admin_cmd(cfg: &Config, command: AdminCommand) -> anyhow::Result<()> {
    let pool = db::connect(&cfg.db).await?;
    let now = clock::unix_now_secs();
    let result = match command {
        AdminCommand::Ban {
            account_id,
            duration,
        } => admin::ban(&pool, account_id, &duration, now).await,
        AdminCommand::Unban { account_id } => admin::unban(&pool, account_id).await,
        AdminCommand::Rename { account_id, name } => {
            admin::rename(&pool, account_id, &name, now).await
        }
        AdminCommand::RemoveRun { run_id } => {
            admin::remove_run(&pool, &cfg.leaderboards, run_id).await
        }
        AdminCommand::Replays => admin::replays(&pool).await,
        AdminCommand::ReplayRequeue { run_id } => admin::replay_requeue(&pool, run_id).await,
        AdminCommand::RemoveEntry {
            board,
            period,
            account_id,
        } => admin::remove_entry(&pool, &board, &period, account_id).await,
        AdminCommand::Reports { unhandled, limit } => admin::reports(&pool, unhandled, limit).await,
        AdminCommand::ReportHandle { report_id } => {
            admin::report_handle(&pool, report_id, now).await
        }
        AdminCommand::CrewRename { crew_id, name, tag } => {
            admin::crew_rename(&pool, crew_id, name.as_deref(), tag.as_deref()).await
        }
        AdminCommand::CrewDisband { crew_id } => admin::crew_disband(&pool, crew_id).await,
    };
    db::close(&pool).await;
    println!("{}", result?);
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
