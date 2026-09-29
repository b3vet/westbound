class_name NetTuning
extends Resource
## Client networking numbers: server URL, accounts API (N1.2), session, keepalive,
## clock sync, WebSocket buffers. Spec: multiplayer handoff → Networking protocol
## (Connection, Clock sync), Accounts and authentication, Tuning reference;
## docs/PROTOCOL.md §1; docs/SERVER.md → Accounts API. Saved as data/tuning/net.tres.
## WP N2.2, N1.2.
## Until the orchestrator adds `Tuning.net`, load it with NetTuning.load_default().
##
## Protocol constants (frame cap, message cap, protocol version) are not tuning: they live
## in NetCodec and change only with a protocol version bump.

const PATH := "res://data/tuning/net.tres"

@export_group("Server")
@export var server_url: String = "wss://westbound.sipsakrandevu.com/ws"

@export_group("Accounts API")
## Base of the HTTP API (docs/SERVER.md → Accounts API). Overridden for local dev by the
## web page's `?server=` parameter or the `--server=` command-line user argument
## (NetSession.resolve_base_url); `off` disables online features.
@export var api_base_url: String = "https://westbound.sipsakrandevu.com/api/v1"
## One HTTP request gives up (network error) after this long.
@export var api_timeout_s: float = 10.0   # not in spec
## Retries after a network error, a 5xx or a 429 (never after another 4xx).
@export var api_max_retries: int = 3   # not in spec
## Exponential backoff between retries: base × 2^attempt, capped, ± jitter (a fraction).
@export var api_backoff_base_s: float = 0.5   # not in spec
@export var api_backoff_max_s: float = 8.0   # not in spec
@export var api_backoff_jitter: float = 0.25   # not in spec
## A 429 is retried after its Retry-After when that is at most this long; a longer wait
## goes back to the caller as `rate_limited` with `retry_after_s`.
@export var api_retry_after_max_s: float = 30.0   # not in spec
## Retry-After fallback when a 429 carries none.
@export var api_retry_after_default_s: float = 5.0   # not in spec

@export_group("Session")
## The access token (1 h) is refreshed this long before it expires.
@export var session_refresh_margin_s: float = 120.0   # not in spec
## Offline (network or server down): the silent sign-in is retried after this long,
## doubling up to the max.
@export var session_retry_s: float = 15.0   # not in spec
@export var session_retry_max_s: float = 300.0   # not in spec
## Display names: the server's rules (docs/SERVER.md → PATCH /me); the client only
## limits the text field and skips obviously short names.
@export var display_name_min_chars: int = 3
@export var display_name_max_chars: int = 16

@export_group("Keepalive")
## Ping cadence until `Welcome` arrives; afterwards `Welcome.ping_interval_ms` wins when set.
@export var ping_interval_s: float = 2.0
## Silence (nothing received) after which the connection is dead; `Welcome.timeout_ms`
## wins when set.
@export var dead_timeout_s: float = 8.0
## No `Welcome` or `Error` within this long after the socket opens: give up.
@export var handshake_timeout_s: float = 10.0   # not in spec
## Socket still not open after this long: give up.
@export var connect_timeout_s: float = 10.0   # not in spec

@export_group("Clock sync")
## Room tick rate until `Welcome.tick_rate_hz` arrives.
@export var tick_rate_hz: float = 20.0
## Most recent Ping/Pong samples kept; the lowest-RTT one sets the target offset.
@export var clock_samples: int = 8
## Largest correction speed while slewing, as a fraction of real time (0.05: the estimated
## server clock runs at most 5 % fast or slow). Must stay below 1 so the clock never runs
## backward.
@export var clock_slew_max_rate: float = 0.05   # not in spec
## Time constant of the slew toward the target once the sample window is full. Averages
## the lowest-RTT pick over successive windows (jitter asymmetry noise).
@export var clock_smoothing_s: float = 30.0   # not in spec: tuned by test_clock (±5 ms at 150 ms RTT)
## Time constant while the window is still filling (fast initial convergence).
@export var clock_settle_smoothing_s: float = 1.0   # not in spec
## A target this far ahead of the estimate is jumped to at once (forward only).
@export var clock_snap_forward_ms: float = 250.0   # not in spec
## Pongs whose round trip exceeds this are ignored as samples (still count as traffic).
@export var clock_max_rtt_ms: float = 2000.0   # not in spec

@export_group("WebSocket")
## Inbound buffer: holds several 16 KB frames.
@export var ws_inbound_buffer_kb: int = 64   # not in spec
## Outbound buffer; `send` refuses frames that would overflow it (ERR_BUSY).
@export var ws_outbound_buffer_kb: int = 64   # not in spec
## Queued packets per direction in WebSocketPeer.
@export var ws_max_queued_packets: int = 256   # not in spec


func ping_interval_usec() -> int:
	return roundi(ping_interval_s * 1.0e6)   # lint: allow-number s -> usec


func dead_timeout_usec() -> int:
	return roundi(dead_timeout_s * 1.0e6)   # lint: allow-number s -> usec


static func load_default() -> NetTuning:
	return load(PATH) as NetTuning
