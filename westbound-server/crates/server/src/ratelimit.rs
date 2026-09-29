//! HTTP rate limits (`tower_governor`): per client IP on the auth routes, per account
//! on authenticated routes. 429 responses use the API error format and carry
//! `Retry-After`. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Accounts and
//! authentication" (security: rate limits per IP and per account).
//!
//! **Client IP.** The TCP peer is the client unless it is a trusted proxy
//! (`http.trusted_proxies`, CIDRs). Behind Coolify's proxy the peer is the proxy, so
//! the client is read from `X-Forwarded-For`, walking right to left past trusted hops;
//! the first untrusted address is the client. A client connecting directly cannot
//! spoof its IP: its own `X-Forwarded-For` is ignored.
//!
//! **Keys.** IPv6 clients are keyed by their /64 (one subscriber's prefix, so rotating
//! addresses inside it does not reset the limit). Authenticated routes key by the
//! account in a validly signed access token (signature only, no database, expiry
//! ignored); requests without one fall back to their IP key. IPs are never logged.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use axum::body::Body;
use axum::extract::ConnectInfo;
use axum::http::{HeaderMap, Request};
use axum::response::{IntoResponse, Response};
use governor::middleware::NoOpMiddleware;
use tower_governor::governor::{GovernorConfig, GovernorConfigBuilder};
use tower_governor::key_extractor::KeyExtractor;
use tower_governor::{GovernorError, GovernorLayer};

use crate::auth::AuthKeys;
use crate::config::Config;
use crate::error::ApiError;
use crate::metrics::Metrics;

const SECS_PER_HOUR: u64 = 3_600;
const SECS_PER_MINUTE: u64 = 60;
/// IPv6 clients are keyed by this prefix length.
const IPV6_KEY_PREFIX: u8 = 64;
/// How often idle limiter entries are dropped.
pub const CLEANUP_INTERVAL: Duration = Duration::from_secs(60);

/// An IPv4 or IPv6 network.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cidr {
    addr: IpAddr,
    prefix: u8,
}

impl Cidr {
    /// `10.0.0.0/8`, `fc00::/7`, or a bare address (a /32 or /128).
    pub fn parse(s: &str) -> Option<Cidr> {
        let s = s.trim();
        let (ip, prefix) = match s.split_once('/') {
            Some((ip, p)) => (ip.parse::<IpAddr>().ok()?, Some(p.parse::<u8>().ok()?)),
            None => (s.parse::<IpAddr>().ok()?, None),
        };
        let max = if ip.is_ipv4() { 32 } else { 128 };
        let prefix = prefix.unwrap_or(max);
        (prefix <= max).then_some(Cidr { addr: ip, prefix })
    }

    pub fn contains(&self, ip: IpAddr) -> bool {
        match (self.addr, canonical(ip)) {
            (IpAddr::V4(net), IpAddr::V4(ip)) => {
                mask_u32(u32::from(net), self.prefix) == mask_u32(u32::from(ip), self.prefix)
            }
            (IpAddr::V6(net), IpAddr::V6(ip)) => {
                mask_u128(u128::from(net), self.prefix) == mask_u128(u128::from(ip), self.prefix)
            }
            _ => false,
        }
    }
}

fn mask_u32(v: u32, prefix: u8) -> u32 {
    if prefix == 0 {
        0
    } else {
        v & (u32::MAX << (32 - u32::from(prefix)))
    }
}

fn mask_u128(v: u128, prefix: u8) -> u128 {
    if prefix == 0 {
        0
    } else {
        v & (u128::MAX << (128 - u32::from(prefix)))
    }
}

/// IPv4-mapped IPv6 (`::ffff:1.2.3.4`) → IPv4.
fn canonical(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V6(v6) => v6
            .to_ipv4_mapped()
            .map(IpAddr::V4)
            .unwrap_or(IpAddr::V6(v6)),
        v4 => v4,
    }
}

/// The trusted proxy networks.
#[derive(Debug, Clone, Default)]
pub struct TrustedProxies(Arc<Vec<Cidr>>);

impl TrustedProxies {
    pub fn from_config(cfg: &Config) -> Self {
        Self(Arc::new(
            cfg.http
                .trusted_proxies
                .iter()
                .filter_map(|s| Cidr::parse(s))
                .collect(),
        ))
    }

    pub fn trusts(&self, ip: IpAddr) -> bool {
        self.0.iter().any(|c| c.contains(ip))
    }

    /// The client address of a request (see the module docs).
    pub fn client_ip<T>(&self, req: &Request<T>) -> IpAddr {
        let peer = req
            .extensions()
            .get::<ConnectInfo<SocketAddr>>()
            .map(|c| c.0.ip())
            .unwrap_or(IpAddr::V4(Ipv4Addr::UNSPECIFIED));
        self.client_ip_from(peer, req.headers())
    }

    /// The client address from the TCP peer and the request headers.
    pub fn client_ip_from(&self, peer: IpAddr, headers: &HeaderMap) -> IpAddr {
        let peer = canonical(peer);
        if !self.trusts(peer) {
            return peer;
        }
        let hops: Vec<&str> = headers
            .get_all("x-forwarded-for")
            .iter()
            .filter_map(|v| v.to_str().ok())
            .flat_map(|v| v.split(','))
            .collect();
        let mut client = peer;
        for hop in hops.iter().rev() {
            let Some(ip) = parse_hop(hop) else { break };
            client = ip;
            if !self.trusts(ip) {
                break;
            }
        }
        client
    }
}

/// One `X-Forwarded-For` entry: an address, optionally `[v6]:port` or `v4:port`.
fn parse_hop(s: &str) -> Option<IpAddr> {
    let s = s.trim();
    s.parse::<IpAddr>()
        .ok()
        .or_else(|| s.parse::<SocketAddr>().ok().map(|a| a.ip()))
        .map(canonical)
}

/// A rate-limit bucket key.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RateKey {
    Ip(IpAddr),
    Account(i64),
}

impl RateKey {
    pub fn ip(ip: IpAddr) -> Self {
        match canonical(ip) {
            IpAddr::V6(v6) => RateKey::Ip(IpAddr::V6(Ipv6Addr::from(mask_u128(
                u128::from(v6),
                IPV6_KEY_PREFIX,
            )))),
            v4 => RateKey::Ip(v4),
        }
    }
}

/// Keys by client IP.
#[derive(Debug, Clone)]
pub struct IpKey {
    proxies: TrustedProxies,
}

impl KeyExtractor for IpKey {
    type Key = RateKey;

    fn extract<T>(&self, req: &Request<T>) -> Result<RateKey, GovernorError> {
        Ok(RateKey::ip(self.proxies.client_ip(req)))
    }
}

/// Keys by the account of a validly signed bearer token, else by client IP.
#[derive(Clone)]
pub struct AccountKey {
    proxies: TrustedProxies,
    keys: Arc<AuthKeys>,
}

impl KeyExtractor for AccountKey {
    type Key = RateKey;

    fn extract<T>(&self, req: &Request<T>) -> Result<RateKey, GovernorError> {
        let account = req
            .headers()
            .get(axum::http::header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.split_once(' '))
            .filter(|(scheme, _)| scheme.eq_ignore_ascii_case("bearer"))
            .and_then(|(_, t)| self.keys.verify_signature(t.trim()).ok());
        Ok(match account {
            Some(v) => RateKey::Account(v.account_id),
            None => RateKey::ip(self.proxies.client_ip(req)),
        })
    }
}

type LimiterConfig<K> = GovernorConfig<K, NoOpMiddleware>;

/// The limiter state for each route class, shared by every router built from one
/// `AppState`.
#[derive(Clone)]
pub struct RateLimiters {
    pub enabled: bool,
    /// Also used by the WebSocket upgrade to find the client behind the proxy.
    pub proxies: TrustedProxies,
    pub device_create: Arc<LimiterConfig<IpKey>>,
    pub auth: Arc<LimiterConfig<IpKey>>,
    pub account: Arc<LimiterConfig<AccountKey>>,
    /// Run submissions per account (N7.1), on top of `account`.
    pub runs: Arc<LimiterConfig<AccountKey>>,
    /// Social writes per account (N9.1: friend requests, blocks, crew create / join,
    /// reports), on top of `account`.
    pub social: Arc<LimiterConfig<AccountKey>>,
    metrics: Arc<Metrics>,
}

fn period(per: u64, window_secs: u64) -> Duration {
    Duration::from_nanos((window_secs * 1_000_000_000) / per.max(1))
}

impl RateLimiters {
    pub fn new(cfg: &Config, keys: Arc<AuthKeys>, metrics: Arc<Metrics>) -> Self {
        let r = &cfg.rate_limits;
        let proxies = TrustedProxies::from_config(cfg);
        let ip = IpKey {
            proxies: proxies.clone(),
        };
        let trusted = proxies.clone();
        let build_ip = |per: u32, window: u64, burst: u32| -> Arc<LimiterConfig<IpKey>> {
            Arc::new(
                GovernorConfigBuilder::default()
                    .key_extractor(ip.clone())
                    .period(period(per.into(), window))
                    .burst_size(burst.max(1))
                    .finish()
                    .expect("validated non-zero rate and burst"),
            )
        };
        let account_key = AccountKey { proxies, keys };
        let build_account = |per: u32, window: u64, burst: u32| {
            Arc::new(
                GovernorConfigBuilder::default()
                    .key_extractor(account_key.clone())
                    .period(period(per.into(), window))
                    .burst_size(burst.max(1))
                    .finish()
                    .expect("validated non-zero rate and burst"),
            )
        };
        let account = build_account(r.account_per_minute, SECS_PER_MINUTE, r.account_burst);
        let runs = build_account(r.runs_per_hour, SECS_PER_HOUR, r.runs_burst);
        let social = build_account(r.social_per_hour, SECS_PER_HOUR, r.social_burst);
        Self {
            enabled: r.enabled,
            device_create: build_ip(
                r.device_create_per_hour,
                SECS_PER_HOUR,
                r.device_create_burst,
            ),
            auth: build_ip(r.auth_per_minute, SECS_PER_MINUTE, r.auth_burst),
            account,
            runs,
            social,
            proxies: trusted,
            metrics,
        }
    }

    fn on_error(metrics: Arc<Metrics>) -> impl Fn(GovernorError) -> Response<Body> + Send + Sync {
        move |e| match e {
            GovernorError::TooManyRequests { wait_time, .. } => {
                Metrics::inc(&metrics.http_rate_limited);
                // governor floors the wait to whole seconds; round up instead.
                ApiError::rate_limited(wait_time + 1).into_response()
            }
            other => ApiError::internal(other).into_response(),
        }
    }

    pub fn layer<K>(&self, config: &Arc<LimiterConfig<K>>) -> GovernorLayer<K, NoOpMiddleware, Body>
    where
        K: KeyExtractor,
        K::Key: Send + Sync + 'static,
    {
        GovernorLayer::new(config.clone()).error_handler(Self::on_error(self.metrics.clone()))
    }

    /// Drops idle buckets (called every `CLEANUP_INTERVAL`).
    pub fn cleanup(&self) {
        for l in [self.device_create.limiter(), self.auth.limiter()] {
            l.retain_recent();
            l.shrink_to_fit();
        }
        for l in [
            self.account.limiter(),
            self.runs.limiter(),
            self.social.limiter(),
        ] {
            l.retain_recent();
            l.shrink_to_fit();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cidr_contains() {
        let c = Cidr::parse("10.0.0.0/8").unwrap();
        assert!(c.contains("10.1.2.3".parse().unwrap()));
        assert!(c.contains("::ffff:10.1.2.3".parse().unwrap()));
        assert!(!c.contains("11.0.0.1".parse().unwrap()));
        let v6 = Cidr::parse("fc00::/7").unwrap();
        assert!(v6.contains("fd12::1".parse().unwrap()));
        assert!(!v6.contains("2001:db8::1".parse().unwrap()));
        assert!(Cidr::parse("1.2.3.4")
            .unwrap()
            .contains("1.2.3.4".parse().unwrap()));
        assert!(Cidr::parse("0.0.0.0/0")
            .unwrap()
            .contains("8.8.8.8".parse().unwrap()));
        assert!(Cidr::parse("10.0.0.0/33").is_none());
        assert!(Cidr::parse("nope").is_none());
    }

    #[test]
    fn ipv6_keys_by_64() {
        let a = RateKey::ip("2001:db8:1:2:aaaa::1".parse().unwrap());
        let b = RateKey::ip("2001:db8:1:2:bbbb::9".parse().unwrap());
        let c = RateKey::ip("2001:db8:1:3::1".parse().unwrap());
        assert_eq!(a, b);
        assert_ne!(a, c);
    }

    #[test]
    fn periods() {
        assert_eq!(period(5, SECS_PER_HOUR), Duration::from_secs(720));
        assert_eq!(period(120, SECS_PER_MINUTE), Duration::from_millis(500));
    }
}
