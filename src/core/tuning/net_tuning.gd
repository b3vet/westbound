class_name NetTuning
extends Resource
## Client networking numbers: server URL, accounts API (N1.2), session, keepalive,
## clock sync, WebSocket buffers. Spec: multiplayer handoff → Networking protocol
## (Connection, Clock sync), Accounts and authentication, Tuning reference;
## docs/PROTOCOL.md §1; docs/SERVER.md → Accounts API. Saved as data/tuning/net.tres.
## WP N2.2, N1.2, N7.2 (runs and leaderboards).
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

@export_group("Runs and leaderboards")
## This build's number (u32), sent as `client_build` with every run submission and in the
## WebSocket Hello. Bump it with every release: the server refuses builds it no longer
## verifies (`build_unsupported`; docs/SERVER.md → POST /runs).
@export var client_build: int = 1
## A run that could not be sent (offline, server down, 429) is tried again after this
## long, doubling up to the max; a 429's Retry-After wins when longer.
@export var runs_retry_s: float = 20.0   # not in spec
@export var runs_retry_max_s: float = 600.0   # not in spec
## Most runs kept waiting on the device; the oldest is dropped past it.
@export var runs_queue_max: int = 50   # not in spec
## A queued run is dropped once the server would refuse its date: this long after the
## end of the UTC day it was played (mirrors the server's `runs.date_late_secs`).
@export var runs_date_late_s: float = 21600.0
## A run that scored nothing and drove less than this is not submitted (a crash at the
## start: it can place on no board, and it would spend the 30-per-hour submission limit).
@export var runs_min_distance_m: float = 500.0   # not in spec
## Board reads: the global top (the server's max) and "around me" ranks on each side.
@export var boards_global_limit: int = 100
@export var boards_around_me_limit: int = 10
## A board page younger than this is shown from memory without asking the server again
## (the server caches its tops for 60 s anyway).
@export var boards_cache_s: float = 30.0   # not in spec
## Pull to refresh asks the server again at most this often.
@export var boards_refresh_min_s: float = 3.0   # not in spec
## Daily Drive: how many previous days the date stepper reaches back.
@export var boards_daily_days_back: int = 14   # not in spec

@export_group("Leaderboards screen")
## List row height and the tab column width, canvas px at 100% text size (touch targets
## never shrink below hud.touch_target_px).
@export var boards_row_px: float = 52.0   # not in spec
@export var boards_tab_width_px: float = 250.0   # not in spec
@export var boards_back_width_px: float = 190.0   # not in spec
## Segmented choices (period, view): the narrowest option.
@export var boards_option_min_px: float = 132.0   # not in spec
## Type: the title (display face), row text and the small chips, canvas px at 100%.
@export var boards_title_px: int = 40
@export var boards_row_font_px: int = 20
@export var boards_chip_font_px: int = 12
## Pull to refresh: drag this far down at the top of the list, then let go.
@export var boards_pull_refresh_px: float = 84.0   # not in spec
## A press that moves less than this is a tap (selects a row), more is a scroll.
@export var boards_tap_slop_px: float = 14.0   # not in spec
## Fling: the list keeps its release speed and loses it at this rate (1/s).
@export var boards_fling_decay: float = 5.0   # not in spec
## The results screen's online line: slides and fades in over this long when the
## server's placements arrive.
@export var boards_reveal_s: float = 0.3   # not in spec

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
