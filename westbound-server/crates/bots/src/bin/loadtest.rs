//! The N10 load test: N rooms × M bots against a running server over the in-process delay
//! layer, and the numbers the spec budgets. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md →
//! Testing → Load test ("20 rooms of 8 bots on a 1-vCPU limit: at or below 50% CPU, tick
//! p99 under 5 ms, under 300 MB of memory, 10 KB/s or less per player"), Netcode harness
//! (the acceptance numbers), Resource budget. Runbook: docs/LOADTEST.md.
//!
//! ```sh
//! cargo run -p bots --release --bin loadtest -- --server ws://127.0.0.1:8080/ws \
//!     --rooms 20 --bots 8 --rtt 150 --jitter 30 --loss 0.02 --secs 600
//! ```
//!
//! The server must accept the bots: `WB_RATE_LIMITS__ENABLED=false` (160 device accounts
//! from one address) and a map hash the bots send (`--map-hash`, default `ab…ab`:
//! `WB_GATEWAY__MAP_HASHES`, or `server.env = dev`, which takes any). Its metrics listener
//! (`--metrics`, default `127.0.0.1:9090`) gives CPU, memory and tick times; `--pid` reads
//! `/proc/<pid>` instead when the metrics are out of reach.
//!
//! Every bot drives through the room's traffic (`DriveMode::Traffic`), claims honestly,
//! runs the client's traffic model (`bots::predict`) and goes through its own delay lines.
//! After all rooms are joined, every bot starts together; the window measured is `--secs`
//! after `--warmup` seconds. Exit code 0 when every target holds (`--strict` makes a miss
//! an error), 1 on a failed run.

use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{bail, Context};
use bots::load::{self, Scrape};
use bots::{
    BotClient, BotConfig, ClaimMode, DriveMode, LinkMode, LinkSim, LinkStats, NetStats, RoomBot,
};
use protocol::{CodeRef, Density, LobbyCommand, MapHash, RoomSettings, TimeMode, Visibility};
use sim::map::LoopMap;
use tokio::task::JoinSet;
use tokio::time::Instant;

const USAGE: &str = "loadtest --server ws://HOST:PORT/ws [--metrics HOST:PORT] [--pid PID] \
[--rooms 20] [--bots 8] [--rtt 150] [--jitter 30] [--loss 0.02] [--mode stream|datagram] \
[--secs 600] [--warmup 10] [--density normal|light|rush] [--map-hash HEX] [--build 100] \
[--seed 1] [--no-link] [--strict]";

/// The spec's budget (Resource budget, Testing → Load test, Netcode harness).
const CPU_PCT_MAX: f64 = 50.0;
const TICK_P99_MS_MAX: f64 = 5.0;
const RSS_MB_MAX: f64 = 300.0;
const DOWN_KBPS_MAX: f64 = 10.0;
const ACCEPT_PCT_MIN: f64 = 99.0;
const FALSE_HITS_PER_H_MAX: f64 = 1.0;
const CORR_MEDIAN_M_MAX: f64 = 0.15;
const CORR_P99_M_MAX: f64 = 0.6;
const LATE_PER_10MIN_MAX: f64 = 1.0;
/// Bots drive this long after the window with claims off, so every claim is decided.
const TAIL: Duration = Duration::from_millis(2_500);
/// Joined bots keep driving in steps this long until everyone starts (a bot that stops
/// driving would jump on its next step: a teleport).
const IDLE_STEP: Duration = Duration::from_millis(250);
/// Account creation and joins running at once.
const JOIN_PARALLEL: usize = 8;
const PCT: f64 = 100.0;
const KB: f64 = 1_000.0;
const MB: f64 = 1_048_576.0;

#[derive(Debug, Clone)]
struct Args {
    server: String,
    http: String,
    metrics: String,
    pid: Option<u32>,
    rooms: usize,
    bots: usize,
    link: Option<LinkSim>,
    secs: u64,
    warmup: u64,
    density: Density,
    map_hash: MapHash,
    build: u32,
    seed: u64,
    strict: bool,
}

fn parse_args() -> anyhow::Result<Args> {
    let mut kv: Vec<(String, Option<String>)> = Vec::new();
    let mut it = std::env::args().skip(1).peekable();
    while let Some(a) = it.next() {
        let Some(name) = a.strip_prefix("--") else {
            bail!("unexpected argument {a}\n{USAGE}");
        };
        if let Some((k, v)) = name.split_once('=') {
            kv.push((k.into(), Some(v.into())));
        } else if it.peek().is_some_and(|n| !n.starts_with("--")) {
            kv.push((name.into(), it.next()));
        } else {
            kv.push((name.into(), None));
        }
    }
    let get = |k: &str| {
        kv.iter()
            .rev()
            .find(|(n, _)| n == k)
            .map(|(_, v)| v.clone())
    };
    let num = |k: &str, d: f64| -> anyhow::Result<f64> {
        match get(k).flatten() {
            Some(v) => v.parse().with_context(|| format!("--{k} {v}")),
            None => Ok(d),
        }
    };
    for (k, _) in &kv {
        let known = [
            "server", "metrics", "pid", "rooms", "bots", "rtt", "jitter", "loss", "mode", "secs",
            "warmup", "density", "map-hash", "build", "seed", "no-link", "strict", "help",
        ];
        if !known.contains(&k.as_str()) {
            bail!("unknown option --{k}\n{USAGE}");
        }
    }
    if get("help").is_some() {
        bail!("{USAGE}");
    }
    let server = get("server")
        .flatten()
        .context(format!("--server is required\n{USAGE}"))?;
    let server = if server.ends_with("/ws") {
        server
    } else {
        format!("{}/ws", server.trim_end_matches('/'))
    };
    let host = server
        .strip_prefix("ws://")
        .context("--server must be ws://HOST:PORT/ws (no TLS)")?
        .trim_end_matches("/ws")
        .to_owned();
    let metrics = get("metrics")
        .flatten()
        .unwrap_or_else(|| {
            let h = host.rsplit_once(':').map_or(host.as_str(), |(h, _)| h);
            format!("{h}:9090")
        })
        .trim_start_matches("http://")
        .trim_end_matches('/')
        .to_owned();
    let mode = match get("mode").flatten().as_deref() {
        None | Some("stream") => LinkMode::Stream,
        Some("datagram") => LinkMode::Datagram,
        Some(m) => bail!("--mode {m}: stream or datagram"),
    };
    let loss = num("loss", 0.02)?;
    // `--loss` is a fraction (0.02 = 2 %); a value above 1 is taken as percent.
    let loss_pct = if loss > 1.0 { loss } else { loss * PCT };
    let link =
        LinkSim::symmetric(num("rtt", 150.0)?, num("jitter", 30.0)?, loss_pct).with_mode(mode);
    let density = match get("density").flatten().as_deref() {
        None | Some("normal") => Density::Normal,
        Some("light") => Density::Light,
        Some("rush") => Density::Rush,
        Some(d) => bail!("--density {d}: light, normal or rush"),
    };
    let hex = get("map-hash").flatten().unwrap_or_else(|| "ab".repeat(32));
    if hex.len() != 64 {
        bail!("--map-hash: 64 hex digits");
    }
    let mut map_hash = [0u8; 32];
    for (i, b) in map_hash.iter_mut().enumerate() {
        *b = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).context("--map-hash")?;
    }
    Ok(Args {
        server,
        http: host,
        metrics,
        pid: get("pid").flatten().map(|p| p.parse()).transpose()?,
        rooms: num("rooms", 20.0)? as usize,
        bots: num("bots", 8.0)? as usize,
        link: get("no-link").is_none().then_some(link),
        secs: num("secs", 600.0)? as u64,
        warmup: num("warmup", 10.0)? as u64,
        density,
        map_hash: MapHash(map_hash),
        build: num("build", 100.0)? as u32,
        seed: num("seed", 1.0)? as u64,
        strict: get("strict").is_some(),
    })
}

/// One bot's numbers.
#[derive(Debug, Default)]
struct BotReport {
    error: Option<String>,
    /// Bytes on the wire down (WebSocket + TLS framing) and payload up, in the window.
    down_wire: u64,
    up_bytes: u64,
    window_s: f64,
    claims: u64,
    rejected: u64,
    hits: u64,
    driven_s: f64,
    net: NetStats,
    up: LinkStats,
    down: LinkStats,
    violations: usize,
    max_frame: usize,
}

fn bot_cfg(a: &Args, room: usize, k: usize) -> BotConfig {
    BotConfig {
        // Around the fast lanes' pace and above: they pass traffic (claims), follow, and
        // change lanes; the area of interest churns.
        speed_mps: 56.0 + ((room * 3 + k) % 10) as f64,
        accel_mps2: 8.0,
        drive: DriveMode::Traffic,
        claims: ClaimMode::Honest,
        link: a.link,
        seed: a.seed.wrapping_mul(1_000_003) + (room * 16 + k) as u64 + 1,
        measure: true,
        ..BotConfig::default()
    }
}

/// The start signal: when every bot starts its warm-up (`None` while rooms join).
type Start = tokio::sync::watch::Receiver<Option<Instant>>;

/// A room's bots: the first creates it, the rest join by code; then they drive at once
/// (until the start, the warm-up, the window and the tail).
async fn join_room(
    a: Arc<Args>,
    map: Arc<LoopMap>,
    room: usize,
    start: Start,
) -> anyhow::Result<Vec<tokio::task::JoinHandle<BotReport>>> {
    let mut out = Vec::with_capacity(a.bots);
    let mut code = None;
    for k in 0..a.bots {
        let (_, token) = bots::http::device_account(&a.http)
            .await
            .context("device account (is WB_RATE_LIMITS__ENABLED=false?)")?;
        let bot = RoomBot::new(map.clone(), bot_cfg(&a, room, k));
        let mut c = BotClient::connect(&a.server, &token, a.map_hash, a.build, bot)
            .await
            .context("handshake (map hash? WB_GATEWAY__MAP_HASHES)")?;
        match &code {
            None => {
                c.join(LobbyCommand::RoomCreate(RoomSettings {
                    visibility: Visibility::Private,
                    max_players: u8::try_from(a.bots).unwrap_or(8),
                    density: a.density,
                    time_mode: TimeMode::Cycle,
                    fixed_cycle_ms: 0,
                }))
                .await?;
                code = c.bot.code.clone();
            }
            Some(code) => {
                c.join(LobbyCommand::RoomJoinCode(CodeRef { code: code.clone() }))
                    .await?;
            }
        }
        out.push(c);
    }
    let (warmup, window) = (Duration::from_secs(a.warmup), Duration::from_secs(a.secs));
    Ok(out
        .into_iter()
        .map(|c| tokio::spawn(drive(c, start.clone(), warmup, window)))
        .collect())
}

/// A bot from the start signal to the end of the tail.
async fn drive(mut c: BotClient, start: Start, warmup: Duration, window: Duration) -> BotReport {
    let mut r = BotReport::default();
    let res: anyhow::Result<()> = async {
        loop {
            let at = *start.borrow();
            let now = Instant::now();
            match at {
                Some(t) if now >= t => break,
                Some(t) => c.drive_for(t - now).await?,
                None => c.drive_for(IDLE_STEP).await?,
            }
        }
        c.drive_for(warmup).await?;
        let (down0, up0) = (c.bot.seen.wire_bytes, c.sent_bytes);
        let t0 = Instant::now();
        c.drive_for(window).await?;
        r.window_s = t0.elapsed().as_secs_f64();
        r.down_wire = c.bot.seen.wire_bytes - down0;
        r.up_bytes = c.sent_bytes - up0;
        c.bot.scorer.stop_claims();
        c.drive_for(TAIL).await?;
        Ok(())
    }
    .await;
    if let Err(e) = res {
        r.error = Some(format!("{e:#}"));
    }
    if let Some((u, d)) = c.link_stats() {
        r.up = u.clone();
        r.down = d.clone();
    }
    let b = c.close().await;
    r.claims = u64::from(b.scorer.stats.total());
    r.rejected = b.seen.claims_rejected() as u64;
    r.hits = u64::from(b.hits_reported);
    r.driven_s = b.driven_s;
    r.violations = b.seen.traffic.violations.len();
    r.max_frame = b.seen.max_frame;
    if let Some(p) = &b.predictor {
        r.net = p.stats.clone();
    }
    r
}

/// Scrapes `/metrics` (and `/proc/<pid>`, when given): the scrape, and the CPU seconds and
/// memory it saw.
async fn scrape(a: &Args) -> (Option<Scrape>, Option<load::ProcSample>) {
    let s = match bots::http::get(&a.metrics, "/metrics").await {
        Ok(text) => Some(Scrape::parse(&text, Instant::now().into_std())),
        Err(e) => {
            eprintln!("metrics at {} not readable: {e:#}", a.metrics);
            None
        }
    };
    (s, a.pid.and_then(load::read_proc))
}

struct Check {
    what: &'static str,
    value: String,
    target: String,
    ok: Option<bool>,
}

fn check(
    what: &'static str,
    value: Option<f64>,
    target: String,
    fmt: &dyn Fn(f64) -> String,
    ok: &dyn Fn(f64) -> bool,
) -> Check {
    Check {
        what,
        value: value.map_or("n/a".into(), fmt),
        target,
        ok: value.map(ok),
    }
}

async fn run(a: Args) -> anyhow::Result<bool> {
    let a = Arc::new(a);
    let map = Arc::new(
        LoopMap::from_json(include_str!("../../../../data/maps/loop_v1.json"))
            .map_err(|e| anyhow::anyhow!("loop_v1: {e:?}"))?,
    );
    println!(
        "LOADTEST server={} metrics={} rooms={} bots={} density={:?} link={} secs={} warmup={}",
        a.server,
        a.metrics,
        a.rooms,
        a.bots,
        a.density,
        a.link.map_or("none".into(), |l| format!(
            "{:.0} ms RTT ±{:.0} ms, {:.1} % loss, {:?}",
            l.rtt_ms(),
            l.up.jitter_ms + l.down.jitter_ms,
            l.up.loss_pct,
            l.mode
        )),
        a.secs,
        a.warmup,
    );
    let joined0 = Instant::now();
    let (go, start_rx) = tokio::sync::watch::channel(None);
    let mut joins = JoinSet::new();
    let mut tasks = Vec::with_capacity(a.rooms * a.bots);
    let mut next = 0;
    while next < a.rooms || !joins.is_empty() {
        while next < a.rooms && joins.len() < JOIN_PARALLEL {
            joins.spawn(join_room(a.clone(), map.clone(), next, start_rx.clone()));
            next += 1;
        }
        if let Some(res) = joins.join_next().await {
            tasks.extend(res.context("join task")??);
        }
    }
    println!(
        "joined {} bots in {} rooms in {:.1} s",
        tasks.len(),
        a.rooms,
        joined0.elapsed().as_secs_f64()
    );
    let start = Instant::now() + Duration::from_secs(1);
    let (warmup, window) = (Duration::from_secs(a.warmup), Duration::from_secs(a.secs));
    let _ = go.send(Some(start));
    tokio::time::sleep_until(start + warmup).await;
    let (s0, p0) = scrape(&a).await;
    let w0 = Instant::now();
    tokio::time::sleep_until(start + warmup + window).await;
    let (s1, p1) = scrape(&a).await;
    let wall = w0.elapsed().as_secs_f64();
    let mut reports = Vec::new();
    for t in tasks {
        reports.push(t.await.context("bot task")?);
    }
    // After the tail: every claim decided.
    let (s2, _) = scrape(&a).await;
    let admin = bots::http::get(&a.metrics, "/admin/stats").await.ok();
    Ok(report(&a, &reports, s0, s1, s2, p0, p1, wall, admin))
}

#[allow(clippy::too_many_arguments)]
fn report(
    a: &Args,
    bots: &[BotReport],
    s0: Option<Scrape>,
    s1: Option<Scrape>,
    s2: Option<Scrape>,
    p0: Option<load::ProcSample>,
    p1: Option<load::ProcSample>,
    wall: f64,
    admin: Option<String>,
) -> bool {
    let errors: Vec<&String> = bots.iter().filter_map(|b| b.error.as_ref()).collect();
    let n = bots.len().max(1) as f64;
    let mut net = NetStats::default();
    let (mut up, mut down) = (LinkStats::default(), LinkStats::default());
    for b in bots {
        net.merge(&b.net);
        up.merge(&b.up);
        down.merge(&b.down);
    }
    let rate = |b: &BotReport, bytes: u64| bytes as f64 / b.window_s.max(1e-3) / KB;
    let down_mean = bots.iter().map(|b| rate(b, b.down_wire)).sum::<f64>() / n;
    let down_worst = bots
        .iter()
        .map(|b| rate(b, b.down_wire))
        .fold(0.0, f64::max);
    let up_mean = bots.iter().map(|b| rate(b, b.up_bytes)).sum::<f64>() / n;
    let driven_s: f64 = bots.iter().map(|b| b.driven_s).sum();
    let sent: u64 = bots.iter().map(|b| b.claims).sum();
    let violations: usize = bots.iter().map(|b| b.violations).sum();
    let max_frame = bots.iter().map(|b| b.max_frame).max().unwrap_or(0);

    // Server numbers over the window (metrics), else /proc.
    let both = s0.as_ref().zip(s1.as_ref());
    let cpu = both
        .map(|(x, y)| load::delta(x, y, "process_cpu_seconds_total") / wall * PCT)
        .filter(|_| {
            s1.as_ref()
                .is_some_and(|s| s.has("process_cpu_seconds_total"))
        })
        .or_else(|| p0.zip(p1).map(|(x, y)| (y.cpu_s - x.cpu_s) / wall * PCT));
    let rss = s1
        .as_ref()
        .filter(|s| s.has("process_resident_memory_bytes"))
        .map(|s| s.get("process_resident_memory_bytes") / MB)
        .or_else(|| p1.map(|p| p.rss_bytes as f64 / MB));
    let rss_peak = s2
        .as_ref()
        .filter(|s| s.has("process_resident_memory_peak_bytes"))
        .map(|s| s.get("process_resident_memory_peak_bytes") / MB)
        .or_else(|| p1.map(|p| p.rss_peak_bytes as f64 / MB));
    const TICK: &str = "wb_room_tick_seconds";
    let ticks = both.map(|(x, y)| load::delta(x, y, &format!("{TICK}_count")));
    let tick_mean_ms = both.map(|(x, y)| {
        load::delta(x, y, &format!("{TICK}_sum"))
            / load::delta(x, y, &format!("{TICK}_count")).max(1.0)
            * KB
    });
    let q = |p: f64| both.map(|(x, y)| load::window_quantile(x, y, TICK, p) * KB);
    let (p50, p99) = (q(0.5), q(0.99));
    let tick_max_ms = s1.as_ref().map(|s| s.get("wb_room_tick_max_seconds") * KB);
    let rooms_cpu = both.map(|(x, y)| load::delta(x, y, &format!("{TICK}_sum")) / wall * PCT);
    let server_down = both.map(|(x, y)| {
        load::delta(x, y, "wb_ws_bytes_out_total") / wall / y.get("wb_ws_sessions").max(1.0) / KB
    });
    let accepted = s2
        .as_ref()
        .map(|s| s.get("wb_room_claims_total{verdict=\"accepted\"}"));
    let rejected = s2.as_ref().map(|s| {
        s.labelled("wb_room_claims_total", "reason")
            .iter()
            .filter(|(r, _)| r != "no_run")
            .map(|(_, v)| v)
            .sum::<f64>()
    });
    let acceptance = accepted
        .zip(rejected)
        .map(|(x, r)| if x + r > 0.0 { PCT * x / (x + r) } else { PCT });
    let offences = s2.as_ref().map(|s| s.sum("wb_room_offences_total"));
    let false_hits = s2.as_ref().map(|s| s.get("wb_room_hits_unreported_total"));
    let hours = driven_s / 3_600.0;
    let late10 = net.late_intents as f64 / (driven_s / 600.0).max(1e-9);

    println!();
    println!(
        "window {wall:.0} s, {} bots ({} failed), {:.1} bot-hours driven, {} ticks",
        bots.len(),
        errors.len(),
        hours,
        ticks.map_or("n/a".into(), |t| format!("{t:.0}"))
    );
    for e in errors.iter().take(5) {
        println!("  bot error: {e}");
    }
    let f1 = |v: f64| format!("{v:.1}");
    let f2 = |v: f64| format!("{v:.2}");
    let f3 = |v: f64| format!("{v:.3}");
    let checks = vec![
        check(
            "Server CPU, % of one core",
            cpu,
            format!("≤ {CPU_PCT_MAX:.0}"),
            &f1,
            &|v| v <= CPU_PCT_MAX,
        ),
        check(
            "Room tick p99 (bucket bound), ms",
            p99,
            format!("< {TICK_P99_MS_MAX:.0}"),
            &f2,
            &|v| v < TICK_P99_MS_MAX,
        ),
        check(
            "Server RSS at the end, MB",
            rss,
            format!("< {RSS_MB_MAX:.0}"),
            &f1,
            &|v| v < RSS_MB_MAX,
        ),
        check(
            "Down per player, worst bot, KB/s (wire)",
            Some(down_worst),
            format!("≤ {DOWN_KBPS_MAX:.0}"),
            &f2,
            &|v| v <= DOWN_KBPS_MAX,
        ),
        check(
            "Claim acceptance, %",
            acceptance,
            format!("> {ACCEPT_PCT_MIN:.0}"),
            &f2,
            &|v| v > ACCEPT_PCT_MIN,
        ),
        check(
            "False server-detected hits per bot-hour",
            false_hits.map(|h| h / hours.max(1e-9)),
            format!("< {FALSE_HITS_PER_H_MAX:.0}"),
            &f2,
            &|v| v < FALSE_HITS_PER_H_MAX,
        ),
        check(
            "Traffic correction median, m",
            Some(net.all.quantile(0.5)),
            format!("< {CORR_MEDIAN_M_MAX}"),
            &f3,
            &|v| v < CORR_MEDIAN_M_MAX,
        ),
        check(
            "Traffic correction p99, m",
            Some(net.all.quantile(0.99)),
            format!("< {CORR_P99_M_MAX}"),
            &f3,
            &|v| v < CORR_P99_M_MAX,
        ),
        check(
            "Late intents per 10 bot-minutes",
            Some(late10),
            format!("< {LATE_PER_10MIN_MAX:.0}"),
            &f2,
            &|v| v < LATE_PER_10MIN_MAX,
        ),
        check(
            "Plausibility offences (honest bots)",
            offences,
            "0".into(),
            &|v| format!("{v:.0}"),
            &|v| v == 0.0,
        ),
    ];
    println!();
    println!("| Measure | Value | Target | |");
    println!("| --- | --- | --- | --- |");
    let mut pass = errors.is_empty();
    for c in &checks {
        let mark = match c.ok {
            Some(true) => "ok",
            Some(false) => {
                pass = false;
                "MISS"
            }
            None => "n/a",
        };
        println!("| {} | {} | {} | {mark} |", c.what, c.value, c.target);
    }
    println!();
    let opt = |v: Option<f64>, f: &dyn Fn(f64) -> String| v.map_or("n/a".into(), f);
    println!(
        "server: rss peak {} MB, tick mean {} ms p50 ≤ {} ms max (since start) {} ms, room ticks {} % of a core, \
         down per session {} KB/s (payload)",
        opt(rss_peak, &f1),
        opt(tick_mean_ms, &f3),
        opt(p50, &f2),
        opt(tick_max_ms, &f1),
        opt(rooms_cpu, &f1),
        opt(server_down, &f2),
    );
    println!(
        "bots: down mean {down_mean:.2} KB/s (wire), up mean {up_mean:.2} KB/s, largest frame {max_frame} B, \
         mirror violations {violations}"
    );
    println!(
        "claims: sent {sent}, accepted {}, rejected {} (bots saw {}), offences {}, false hits {}, hits reported {}",
        opt(accepted, &|v| format!("{v:.0}")),
        opt(rejected, &|v| format!("{v:.0}")),
        bots.iter().map(|b| b.rejected).sum::<u64>(),
        opt(offences, &|v| format!("{v:.0}")),
        opt(false_hits, &|v| format!("{v:.0}")),
        bots.iter().map(|b| b.hits).sum::<u64>(),
    );
    if let Some(s) = &s2 {
        let reasons: Vec<String> = s
            .labelled("wb_room_claims_total", "reason")
            .into_iter()
            .filter(|(_, v)| *v > 0.0)
            .map(|(r, v)| format!("{r}={v:.0}"))
            .collect();
        let off: Vec<String> = s
            .labelled("wb_room_offences_total", "kind")
            .into_iter()
            .filter(|(_, v)| *v > 0.0)
            .map(|(r, v)| format!("{r}={v:.0}"))
            .collect();
        println!(
            "  rejections [{}] offences [{}]",
            reasons.join(" "),
            off.join(" ")
        );
        println!(
            "  shadow: {:.0} player contacts over {:.0} pair-ticks, {:.0} rows written, hits confirmed {:.0} refused {:.0}",
            s.get("wb_room_shadow_contact_disagreement_meters_count"),
            s.get("wb_room_shadow_contact_ticks_total"),
            s.get("wb_room_shadow_rows_written_total"),
            s.get("wb_room_hits_confirmed_total"),
            s.get("wb_room_hits_refused_total"),
        );
    }
    println!(
        "corrections: n={} median={:.3} p99={:.3} max={:.2} m | near n={} median={:.3} p99={:.3} max={:.2} m | \
         dead reckoning median={:.3} p99={:.3} m | large in view {} | unsignaled {}",
        net.all.n,
        net.all.quantile(0.5),
        net.all.quantile(0.99),
        net.all.max,
        net.near.n,
        net.near.quantile(0.5),
        net.near.quantile(0.99),
        net.near.max,
        net.dead_reckoning.quantile(0.5),
        net.dead_reckoning.quantile(0.99),
        net.large_in_view,
        net.unsignaled_lateral,
    );
    println!(
        "intents: {} lane changes, {} late, {} very late, cancels {} (after the move {}), model re-anchors {}",
        net.intents, net.late_intents, net.very_late_intents, net.cancels, net.late_cancels, net.reanchors
    );
    if a.link.is_some() {
        println!(
            "link up: frames {} lost {:.2} % delay mean {:.1} p99 {} max {} ms | down: frames {} lost {:.2} % \
             held {} dropped {} delay mean {:.1} p99 {} max {} ms",
            up.frames,
            up.loss_pct(),
            up.mean_ms(),
            up.quantile_ms(0.99),
            up.max_ms(),
            down.frames,
            down.loss_pct(),
            down.held,
            down.dropped,
            down.mean_ms(),
            down.quantile_ms(0.99),
            down.max_ms(),
        );
    }
    if let Some(j) = admin {
        println!("admin stats: {j}");
    }
    println!("RESULT {}", if pass { "PASS" } else { "MISS" });
    pass
}

fn main() -> ExitCode {
    let args = match parse_args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("{e:#}");
            return ExitCode::from(2);
        }
    };
    let strict = args.strict;
    let rt = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("runtime: {e}");
            return ExitCode::FAILURE;
        }
    };
    match rt.block_on(run(args)) {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) if !strict => ExitCode::SUCCESS,
        Ok(false) => ExitCode::from(3),
        Err(e) => {
            eprintln!("load test failed: {e:#}");
            ExitCode::FAILURE
        }
    }
}
