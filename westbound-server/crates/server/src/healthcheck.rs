//! `westbound-server healthcheck`: a minimal HTTP/1.1 GET of `/api/v1/health` on
//! localhost, for the Docker `HEALTHCHECK` (the runtime image has no curl).

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::time::Duration;

use anyhow::{bail, Context};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

pub const HEALTH_PATH: &str = "/api/v1/health";
/// Cap on the response read, so a misbehaving peer cannot make the probe grow.
const MAX_RESPONSE_BYTES: u64 = 64 * 1024;

/// The address to probe for a bind address: an unspecified bind (`0.0.0.0`,
/// `[::]`) is probed on the loopback of the same family.
pub fn probe_addr(bind: SocketAddr) -> SocketAddr {
    let ip = match bind.ip() {
        IpAddr::V4(a) if a.is_unspecified() => IpAddr::V4(Ipv4Addr::LOCALHOST),
        IpAddr::V6(a) if a.is_unspecified() => IpAddr::V6(Ipv6Addr::LOCALHOST),
        ip => ip,
    };
    SocketAddr::new(ip, bind.port())
}

/// A parsed response: status code and body.
#[derive(Debug)]
pub struct HttpResponse {
    pub status: u16,
    pub body: String,
}

/// `GET path` over plain HTTP/1.1 with `Connection: close`.
pub async fn get(addr: SocketAddr, path: &str, timeout: Duration) -> anyhow::Result<HttpResponse> {
    let fut = async {
        let mut stream = TcpStream::connect(addr)
            .await
            .with_context(|| format!("connecting to {addr}"))?;
        let req = format!(
            "GET {path} HTTP/1.1\r\nHost: {addr}\r\nUser-Agent: westbound-healthcheck\r\nConnection: close\r\n\r\n"
        );
        stream.write_all(req.as_bytes()).await?;
        let mut buf = Vec::new();
        stream
            .take(MAX_RESPONSE_BYTES)
            .read_to_end(&mut buf)
            .await?;
        parse_response(&buf)
    };
    tokio::time::timeout(timeout, fut)
        .await
        .context("health check timed out")?
}

fn parse_response(buf: &[u8]) -> anyhow::Result<HttpResponse> {
    let text = String::from_utf8_lossy(buf);
    let (head, body) = text
        .split_once("\r\n\r\n")
        .context("malformed HTTP response")?;
    let status_line = head.lines().next().unwrap_or_default();
    let status: u16 = status_line
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .context("malformed HTTP status line")?;
    let chunked = head.lines().any(|l| {
        let l = l.to_ascii_lowercase();
        l.starts_with("transfer-encoding:") && l.contains("chunked")
    });
    let body = if chunked {
        dechunk(body)
    } else {
        body.to_string()
    };
    Ok(HttpResponse { status, body })
}

fn dechunk(mut s: &str) -> String {
    let mut out = String::new();
    while let Some((size, rest)) = s.split_once("\r\n") {
        let Ok(n) = usize::from_str_radix(size.trim(), 16) else {
            break;
        };
        if n == 0 || rest.len() < n {
            break;
        }
        out.push_str(&rest[..n]);
        s = rest[n..].trim_start_matches("\r\n");
    }
    out
}

/// Probes the health route; `Ok` only for HTTP 200 with `"status":"ok"`.
pub async fn check(bind: SocketAddr, timeout: Duration) -> anyhow::Result<crate::http::Health> {
    let resp = get(probe_addr(bind), HEALTH_PATH, timeout).await?;
    let health: crate::http::Health =
        serde_json::from_str(&resp.body).context("health body is not the expected JSON")?;
    if resp.status != 200 || health.status != "ok" {
        bail!("unhealthy: HTTP {} {}", resp.status, resp.body.trim());
    }
    Ok(health)
}
