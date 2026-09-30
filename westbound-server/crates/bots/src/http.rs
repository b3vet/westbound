//! Device accounts for bots over plain HTTP/1.1 (`POST /api/v1/auth/device`), without an
//! HTTP client dependency. Local test servers only (no TLS).

use anyhow::{bail, Context};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

/// A new device account on the server at `addr` (`host:port`): (account id, access token).
pub async fn device_account(addr: &str) -> anyhow::Result<(u64, String)> {
    let mut s = TcpStream::connect(addr)
        .await
        .with_context(|| format!("connecting {addr}"))?;
    let req = format!(
        "POST /api/v1/auth/device HTTP/1.1\r\nHost: {addr}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    );
    s.write_all(req.as_bytes()).await?;
    let mut buf = Vec::new();
    s.read_to_end(&mut buf).await?;
    let text = String::from_utf8_lossy(&buf);
    let Some((head, body)) = text.split_once("\r\n\r\n") else {
        bail!("no HTTP response");
    };
    if !head.starts_with("HTTP/1.1 201") {
        bail!(
            "device account refused: {}",
            head.lines().next().unwrap_or("")
        );
    }
    let v: serde_json::Value = serde_json::from_str(body).context("device account JSON")?;
    let id = v["account_id"]
        .as_str()
        .and_then(|s| s.parse().ok())
        .context("account_id")?;
    let token = v["access_token"]
        .as_str()
        .context("access_token")?
        .to_owned();
    Ok((id, token))
}
