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

/// `GET path` on `addr` (`host:port`): the body of a 200 answer (N10.1: `/metrics` and
/// `/admin/stats` for the load test).
pub async fn get(addr: &str, path: &str) -> anyhow::Result<String> {
    let mut s = TcpStream::connect(addr)
        .await
        .with_context(|| format!("connecting {addr}"))?;
    let req = format!("GET {path} HTTP/1.1\r\nHost: {addr}\r\nConnection: close\r\n\r\n");
    s.write_all(req.as_bytes()).await?;
    let mut buf = Vec::new();
    s.read_to_end(&mut buf).await?;
    let text = String::from_utf8_lossy(&buf);
    let Some((head, body)) = text.split_once("\r\n\r\n") else {
        bail!("no HTTP response");
    };
    if !head.starts_with("HTTP/1.1 200") {
        bail!("GET {path}: {}", head.lines().next().unwrap_or(""));
    }
    // A chunked body (axum streams large ones): join the chunks.
    if head
        .to_ascii_lowercase()
        .contains("transfer-encoding: chunked")
    {
        let mut out = String::new();
        let mut rest = body;
        while let Some((size, tail)) = rest.split_once("\r\n") {
            let n = usize::from_str_radix(size.trim(), 16).context("chunk size")?;
            if n == 0 {
                break;
            }
            out.push_str(tail.get(..n).context("short chunk")?);
            rest = tail.get(n + 2..).unwrap_or("");
        }
        return Ok(out);
    }
    Ok(body.to_owned())
}
