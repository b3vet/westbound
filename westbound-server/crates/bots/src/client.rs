//! A bot on a real WebSocket (N5.1): `Hello` → `Welcome`, room commands, and a 20 Hz drive
//! loop that sends the [`RoomBot`]'s states and a ping every 2 s while reading the server's
//! frames. Used by the server's integration tests and the rooms bench (N rooms × M bots in
//! one process). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Testing → Netcode harness, Load
//! test; docs/PROTOCOL.md §1, §5.

use std::time::Duration;

use anyhow::{bail, Context};
use futures_util::{SinkExt, StreamExt};
use protocol::{
    decode_server_frame, encode_frame, AccessToken, ClientMsg, Hello, LobbyCommand, MapHash,
    ServerMsg, Welcome, PROTOCOL_VERSION,
};
use tokio::net::TcpStream;
use tokio::time::Instant;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

use crate::bot::RoomBot;
use crate::link::{DelayLine, LinkStats};

pub type Ws = WebSocketStream<MaybeTlsStream<TcpStream>>;

/// How long a bot waits for any one answer.
pub const ANSWER_TIMEOUT: Duration = Duration::from_secs(5);
/// Client ping interval (`Welcome.ping_interval_ms` is the same).
pub const PING_EVERY: Duration = Duration::from_secs(2);
/// Seeds of the two directions' delay lines (mixed with the bot's seed).
const UP_SEED: u64 = 0x55;
const DOWN_SEED: u64 = 0xAA;
/// When no frame is on the simulated link, the next check (the drive loop's tick wakes
/// it long before).
const IDLE_WAKE: Duration = Duration::from_secs(1);

pub struct BotClient {
    ws: Ws,
    pub bot: RoomBot,
    pub welcome: Welcome,
    epoch: Instant,
    last_ping: Option<Instant>,
    /// N4.4: the simulated link (`bot.cfg.link`): client → server and back.
    up: Option<DelayLine<Vec<u8>>>,
    down: Option<DelayLine<Vec<u8>>>,
}

impl BotClient {
    /// Connects to `url` (`ws://host:port/ws`) and completes the handshake.
    pub async fn connect(
        url: &str,
        token: &str,
        map_hash: MapHash,
        client_build: u32,
        bot: RoomBot,
    ) -> anyhow::Result<Self> {
        let (ws, _) = tokio_tungstenite::connect_async(url)
            .await
            .with_context(|| format!("connecting {url}"))?;
        let link = bot.cfg.link;
        let seed = bot.cfg.seed;
        let mut c = Self {
            ws,
            bot,
            welcome: Welcome::default(),
            epoch: Instant::now(),
            last_ping: None,
            up: link.map(|l| DelayLine::new(l, true, seed ^ UP_SEED)),
            down: link.map(|l| DelayLine::new(l, false, seed ^ DOWN_SEED)),
        };
        let hello = ClientMsg::Hello(Hello {
            protocol_version: PROTOCOL_VERSION,
            client_build,
            map_hash,
            access_token: AccessToken::new(token).context("access token")?,
        });
        c.send(&[hello]).await?;
        let deadline = Instant::now() + ANSWER_TIMEOUT;
        loop {
            let (msgs, bytes) = c.recv_raw(deadline).await?;
            for m in msgs {
                match m {
                    ServerMsg::Welcome(w) => {
                        c.welcome = w;
                        // What came with Welcome (N9.3: a reconnect's party state) goes to
                        // the bot.
                        let now = c.now_ms();
                        c.bot.on_frame(&bytes, now)?;
                        return Ok(c);
                    }
                    ServerMsg::Error(e) => bail!("handshake refused: {:?} {}", e.code, e.detail.0),
                    _ => {}
                }
            }
        }
    }

    /// Local milliseconds since the connection started (the bot's clock).
    pub fn now_ms(&self) -> u64 {
        u64::try_from(self.epoch.elapsed().as_millis()).unwrap_or(u64::MAX)
    }

    pub async fn send(&mut self, msgs: &[ClientMsg]) -> anyhow::Result<()> {
        let frame = encode_frame(msgs).context("encoding")?;
        self.ws
            .send(Message::Binary(frame.to_vec().into()))
            .await
            .context("sending")?;
        Ok(())
    }

    /// Decoded messages of the next binary frame (not fed to the bot), and its bytes.
    async fn recv_raw(&mut self, deadline: Instant) -> anyhow::Result<(Vec<ServerMsg>, Vec<u8>)> {
        loop {
            let next = tokio::time::timeout_at(deadline, self.ws.next())
                .await
                .context("timed out waiting for the server")?;
            match next {
                Some(Ok(Message::Binary(b))) => return Ok((decode_server_frame(&b)?, b.to_vec())),
                Some(Ok(Message::Close(c))) => bail!("closed by the server: {c:?}"),
                Some(Ok(_)) => continue,
                Some(Err(e)) => bail!("websocket: {e}"),
                None => bail!("connection ended"),
            }
        }
    }

    /// Reads one frame into the bot; false on timeout.
    async fn pump_once(&mut self, deadline: Instant) -> anyhow::Result<bool> {
        let next = match tokio::time::timeout_at(deadline, self.ws.next()).await {
            Ok(n) => n,
            Err(_) => return Ok(false),
        };
        match next {
            Some(Ok(Message::Binary(b))) => {
                let now = self.now_ms();
                self.bot.on_frame(&b, now)?;
                Ok(true)
            }
            Some(Ok(Message::Close(c))) => bail!("closed by the server: {c:?}"),
            Some(Ok(_)) => Ok(true),
            Some(Err(e)) => bail!("websocket: {e}"),
            None => bail!("connection ended"),
        }
    }

    /// Reads frames until `done(bot)` or the timeout; returns whether `done` held.
    pub async fn pump_until(
        &mut self,
        timeout: Duration,
        mut done: impl FnMut(&RoomBot) -> bool,
    ) -> anyhow::Result<bool> {
        let deadline = Instant::now() + timeout;
        while !done(&self.bot) {
            if !self.pump_once(deadline).await? {
                return Ok(done(&self.bot));
            }
        }
        Ok(true)
    }

    /// Sends a lobby command and waits for its room snapshot (or an error).
    pub async fn join(&mut self, cmd: LobbyCommand) -> anyhow::Result<()> {
        let snapshots = self.bot.seen.snapshots;
        let errors = self.bot.seen.errors.len();
        self.send(&[ClientMsg::LobbyCommand(cmd)]).await?;
        self.pump_until(ANSWER_TIMEOUT, |b| {
            b.seen.snapshots > snapshots || b.seen.errors.len() > errors
        })
        .await?;
        if let Some(e) = self.bot.seen.errors.get(errors) {
            bail!("join refused: {:?} {}", e.code, e.detail.0);
        }
        if self.bot.seen.snapshots == snapshots {
            bail!("no room snapshot");
        }
        // The placement comes in the snapshot's frame; wait for it if it did not.
        let placements = self.bot.seen.placements;
        if placements == 0 {
            self.pump_until(ANSWER_TIMEOUT, |b| b.seen.placements > 0)
                .await?;
        }
        Ok(())
    }

    /// The simulated link's statistics (client → server, server → client), if any.
    pub fn link_stats(&self) -> Option<(&LinkStats, &LinkStats)> {
        Some((&self.up.as_ref()?.stats, &self.down.as_ref()?.stats))
    }

    /// When the next frame on the simulated link is due.
    fn next_due(&self) -> Instant {
        let due = [&self.up, &self.down]
            .into_iter()
            .filter_map(|l| l.as_ref()?.next_due())
            .min();
        match due {
            Some(ms) => self.epoch + Duration::from_millis(ms),
            None => Instant::now() + IDLE_WAKE,
        }
    }

    /// Sends and delivers every frame due on the simulated link by `now_ms`.
    async fn flush_link(&mut self, now_ms: u64) -> anyhow::Result<()> {
        while let Some(f) = self.up.as_mut().and_then(|l| l.pop_due(now_ms)) {
            self.ws
                .send(Message::Binary(f.into()))
                .await
                .context("sending")?;
        }
        let now = self.now_ms();
        while let Some(b) = self.down.as_mut().and_then(|l| l.pop_due(now_ms)) {
            self.bot.on_frame(&b, now)?;
        }
        Ok(())
    }

    /// Drives for `dur`: a state every room tick (with the claims its rules made, N6.1), a
    /// ping every 2 s, frames read as they come. With `cfg.link` every frame each way goes
    /// through the connection's [`DelayLine`]s (N4.4), which wake the loop when a frame is
    /// due.
    pub async fn drive_for(&mut self, dur: Duration) -> anyhow::Result<()> {
        let end = Instant::now() + dur;
        let tick = Duration::from_secs_f64(1.0 / self.bot.cfg.tick_rate_hz);
        let mut timer = tokio::time::interval(tick);
        timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let linked = self.up.is_some();
        while Instant::now() < end {
            let due = self.next_due();
            tokio::select! {
                _ = timer.tick() => {
                    let now = self.now_ms();
                    let mut out: Vec<ClientMsg> = Vec::with_capacity(4);
                    if let Some(st) = self.bot.step(now) {
                        out.push(ClientMsg::PlayerState(st));
                    }
                    out.extend(self.bot.take_claims());
                    if self.last_ping.is_none_or(|t| t.elapsed() >= PING_EVERY) {
                        self.last_ping = Some(Instant::now());
                        out.push(self.bot.ping(now));
                    }
                    if !out.is_empty() {
                        match self.up.as_mut() {
                            Some(line) => {
                                let frame = encode_frame(&out).context("encoding")?;
                                let n = frame.len();
                                line.push_sized(now, frame.to_vec(), n);
                            }
                            None => self.send(&out).await?,
                        }
                    }
                }
                _ = tokio::time::sleep_until(due), if linked => {
                    let now = self.now_ms();
                    self.flush_link(now).await?;
                }
                next = self.ws.next() => match next {
                    Some(Ok(Message::Binary(b))) => {
                        let now = self.now_ms();
                        match self.down.as_mut() {
                            Some(line) => {
                                let n = b.len();
                                line.push_sized(now, b.to_vec(), n);
                            }
                            None => self.bot.on_frame(&b, now)?,
                        }
                    }
                    Some(Ok(Message::Close(c))) => bail!("closed by the server: {c:?}"),
                    Some(Ok(_)) => {}
                    Some(Err(e)) => bail!("websocket: {e}"),
                    None => bail!("connection ended"),
                },
            }
        }
        // Nothing sent is lost when the drive ends: the frames still on the link go now.
        self.flush_link(u64::MAX).await
    }

    /// Closes the socket (a drop from the room's point of view: the seat is held).
    pub async fn close(mut self) -> RoomBot {
        let _ = self.ws.close(None).await;
        self.bot
    }
}
