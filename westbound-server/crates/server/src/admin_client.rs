//! The `admin` CLI's side of the admin API (N10.2): a minimal HTTP/1.1 client over
//! loopback (the runtime image has no curl), with the bearer token from the same config
//! the server reads (`WB_ADMIN__TOKEN` inside the container).

use std::net::SocketAddr;
use std::time::Duration;

use anyhow::{bail, Context};
use serde::de::DeserializeOwned;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use crate::config::Config;

/// Cap on a response read.
const MAX_RESPONSE_BYTES: u64 = 4 * 1024 * 1024;

/// Where and how to reach the running server's admin API.
#[derive(Debug, Clone)]
pub struct AdminClient {
    addr: SocketAddr,
    token: String,
    timeout: Duration,
}

impl AdminClient {
    /// From the config; `Err` when the API is off (disabled or no token).
    pub fn from_config(cfg: &Config) -> anyhow::Result<Self> {
        let a = &cfg.admin;
        if !a.enabled || a.token.is_empty() {
            bail!(
                "the admin API is off: set WB_ADMIN__TOKEN (32+ bytes) on the server and redeploy \
                 (docs/OPERATIONS.md → Admin API)"
            );
        }
        let bind: SocketAddr = a
            .bind
            .parse()
            .with_context(|| format!("admin.bind `{}`", a.bind))?;
        Ok(Self {
            addr: crate::healthcheck::probe_addr(bind),
            token: a.token.expose().to_string(),
            timeout: Duration::from_millis(a.request_timeout_ms),
        })
    }

    /// A client for `addr` (tests).
    pub fn new(addr: SocketAddr, token: &str, timeout: Duration) -> Self {
        Self {
            addr,
            token: token.to_string(),
            timeout,
        }
    }

    /// `GET path` → JSON.
    pub async fn get<T: DeserializeOwned>(&self, path: &str) -> anyhow::Result<T> {
        self.call("GET", path, None).await
    }

    /// `POST path` with a JSON body → JSON.
    pub async fn post<T: DeserializeOwned>(
        &self,
        path: &str,
        body: &serde_json::Value,
    ) -> anyhow::Result<T> {
        self.call("POST", path, Some(body)).await
    }

    async fn call<T: DeserializeOwned>(
        &self,
        method: &str,
        path: &str,
        body: Option<&serde_json::Value>,
    ) -> anyhow::Result<T> {
        let (status, text) = self.raw(method, path, body).await?;
        if status != 200 {
            let msg = serde_json::from_str::<serde_json::Value>(&text)
                .ok()
                .and_then(|v| v["error"].as_str().map(String::from))
                .unwrap_or_else(|| text.trim().to_string());
            bail!("admin API {method} {path}: HTTP {status}: {msg}");
        }
        serde_json::from_str(&text).with_context(|| format!("admin API {path}: bad JSON"))
    }

    /// One request; (status, body).
    pub async fn raw(
        &self,
        method: &str,
        path: &str,
        body: Option<&serde_json::Value>,
    ) -> anyhow::Result<(u16, String)> {
        let payload = body.map(|b| b.to_string()).unwrap_or_default();
        let fut = async {
            let mut stream = TcpStream::connect(self.addr).await.with_context(|| {
                format!(
                    "connecting to the admin API on {} (is the server running?)",
                    self.addr
                )
            })?;
            let req = format!(
                "{method} {path} HTTP/1.1\r\nHost: {}\r\nUser-Agent: westbound-admin\r\n\
                 Authorization: Bearer {}\r\nContent-Type: application/json\r\n\
                 Content-Length: {}\r\nConnection: close\r\n\r\n{payload}",
                self.addr,
                self.token,
                payload.len()
            );
            stream.write_all(req.as_bytes()).await?;
            let mut buf = Vec::new();
            stream
                .take(MAX_RESPONSE_BYTES)
                .read_to_end(&mut buf)
                .await?;
            parse(&buf)
        };
        tokio::time::timeout(self.timeout, fut)
            .await
            .context("the admin API did not answer in time")?
    }
}

/// Status and (de-chunked) body of an HTTP/1.1 response.
fn parse(buf: &[u8]) -> anyhow::Result<(u16, String)> {
    let text = String::from_utf8_lossy(buf);
    let (head, body) = text
        .split_once("\r\n\r\n")
        .context("malformed HTTP response")?;
    let status: u16 = head
        .lines()
        .next()
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|s| s.parse().ok())
        .context("malformed HTTP status line")?;
    let chunked = head.lines().any(|l| {
        let l = l.to_ascii_lowercase();
        l.starts_with("transfer-encoding:") && l.contains("chunked")
    });
    if !chunked {
        return Ok((status, body.to_string()));
    }
    let mut out = String::new();
    let mut s = body;
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
    Ok((status, out))
}

#[cfg(test)]
mod tests {
    use super::parse;

    #[test]
    fn parses_plain_and_chunked() {
        let (s, b) = parse(b"HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\n{}").unwrap();
        assert_eq!((s, b.as_str()), (200, "{}"));
        let (s, b) = parse(
            b"HTTP/1.1 401 Unauthorized\r\ntransfer-encoding: chunked\r\n\r\n3\r\n{\"a\r\n2\r\n\"}\r\n0\r\n\r\n",
        )
        .unwrap();
        assert_eq!((s, b.as_str()), (401, "{\"a\"}"));
        assert!(parse(b"nonsense").is_err());
    }
}
