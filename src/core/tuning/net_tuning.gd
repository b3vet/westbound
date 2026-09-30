class_name NetTuning
extends Resource
## Client networking numbers: server URL, accounts API (N1.2), session, keepalive,
## clock sync, WebSocket buffers, runs and boards (N7.2), the social client (N9.2), replays
## and the replay verifier (N8.1). Spec: multiplayer handoff → Networking protocol
## (Connection, Clock sync), Accounts and authentication, Tuning reference;
## docs/PROTOCOL.md §1; docs/SERVER.md → Accounts API. Saved as data/tuning/net.tres.
## WP N2.2, N1.2, N7.2 (runs and leaderboards), N9.2 (social), N8.1 (replays).
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

@export_group("Social")
## Friends screen open without a live lobby WebSocket: GET /presence this often (WP N9.2).
@export var social_presence_poll_s: float = 15.0   # not in spec
## The friend code field: a name (16) + "#" + four digits.
@export var friend_code_max_chars: int = 21
## Crew names and tags (docs/SERVER.md → Social API → Crews: 3–24 and 2–4 characters).
@export var crew_name_min_chars: int = 3
@export var crew_name_max_chars: int = 24
@export var crew_tag_min_chars: int = 2
@export var crew_tag_max_chars: int = 4
## Invite codes: the server's `social.crew_invite_code_len` range (6–16; default 8).
@export var crew_code_min_chars: int = 6
@export var crew_code_max_chars: int = 16
## The Loop crew board's "around me" window for the crew screen's season standing.
@export var crew_board_around: int = 1   # not in spec
## How long a "Copied." note stays on the crew screen.
@export var social_note_s: float = 3.0   # not in spec
## Web on a touch screen: a tap on a text field opens the browser's text prompt (iOS
## Safari does not open its keyboard for Godot's field). Off: the field as on desktop.
@export var web_text_prompt: bool = true   # not in spec

@export_group("Rooms (N5.2)")
## Remote players are shown this far behind the room clock, interpolated between their
## states (spec: 100 ms), and extrapolated at most this far past the newest one (spec:
## 250 ms); after that they fade out over room_fade_out_s until data arrives.
@export var room_interp_delay_ms: float = 100.0
@export var room_extrap_max_ms: float = 250.0
@export var room_fade_out_s: float = 0.5   # not in spec
## States kept per remote player (at 20 Hz: 0.8 s).
@export var room_track_samples: int = 16   # not in spec
## A remote state this far from where its track predicts is a teleport (a server
## placement): the car jumps instead of sliding there.
@export var room_snap_distance_m: float = 40.0   # not in spec
## Other players drawn at once (spec: up to 8 players in a room).
@export var room_max_remotes: int = 7
## Spawn and rejoin protection: no traffic hits (spec: 3 s).
@export var room_protection_s: float = 3.0
## A dropped connection is retried every room_reconnect_retry_s; the seat is held this
## long (spec: 15 s), then the run is over and the player goes back to the hub.
@export var room_reconnect_window_s: float = 15.0
@export var room_reconnect_retry_s: float = 1.0   # not in spec
## A join (create, code, id, Quick Join) not answered within this long fails.
@export var room_join_timeout_s: float = 10.0   # not in spec
## The crash-out results toast (spec: 3 s).
@export var room_result_toast_s: float = 3.0
## Ghosting (spec: "translucent when within 15 m of you and fully ghostly when
## overlapping"): the remote car's opacity near you and when overlapping.
@export var room_ghost_near_m: float = 15.0
@export var room_ghost_near_opacity: float = 0.55   # not in spec
@export var room_ghost_overlap_opacity: float = 0.2   # not in spec
## Nametags: shown up to this far along the loop, this high above the road.
@export var room_nametag_max_m: float = 350.0   # not in spec
@export var room_nametag_lift_m: float = 1.8   # not in spec
## Crew colors for nametags and strip dots (RoomCrew.color indexes it, wrapping).
@export var room_crew_colors: PackedColorArray = PackedColorArray([
	Color(0.2, 0.85, 1.0), Color(1.0, 0.45, 0.3), Color(0.55, 1.0, 0.35), Color(1.0, 0.8, 0.2),
	Color(0.85, 0.45, 1.0), Color(1.0, 0.35, 0.65), Color(0.35, 1.0, 0.8), Color(0.95, 0.95, 0.95),
])   # not in spec
## The car model remote players are drawn with (index into Run.CAR_PATHS; the protocol
## carries no car).
@export var room_remote_car: int = 0   # not in spec
## Quick chat: one message per this long from this device (the server rate-limits too);
## a message stays on the feed and the sender's nametag this long; feed lines.
@export var room_chat_interval_s: float = 1.0   # not in spec
@export var room_chat_show_s: float = 4.0   # not in spec
@export var room_chat_feed_lines: int = 3   # not in spec
## The room browser asks again this often while open.
@export var room_browse_refresh_s: float = 5.0   # not in spec
## PRIVATE ROOM time options held at a fixed time: minutes into the 32 min cycle
## (morning; golden hour). NIGHT uses the protocol's `night` mode.
@export var room_fixed_morning_min: float = 3.0   # not in spec
@export var room_fixed_golden_min: float = 18.0   # not in spec
## The seam for N4.3: in a room the local traffic director keeps running as in loop
## practice until the network traffic source replaces it (then false).
@export var room_local_traffic: bool = true   # not in spec
## Room HUD sizes, canvas px at 100% text size: the loop strip, the room line and
## buttons, the room panel.
@export var room_strip_width_px: float = 520.0   # not in spec
@export var room_strip_height_px: float = 6.0   # not in spec
@export var room_strip_dot_px: float = 6.0   # not in spec
@export var room_font_px: int = 16   # not in spec
@export var room_button_width_px: float = 200.0   # not in spec
@export var room_panel_width_px: float = 620.0   # not in spec
@export var room_nametag_font_px: int = 15   # not in spec

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

@export_group("Replays")
## N8.1 (docs/REPLAY_FORMAT.md). The recorder samples the path and inputs every this many
## 120 Hz physics ticks: 4 = the spec's 30 Hz. Discontinuities (a fork swap, the safety
## net) and the run's last tick are always sampled.
@export var replay_sample_ticks: int = 4
## The traffic fingerprint goes into the replay every this many ticks (120 = once a
## second): the verifier finds where its traffic diverged from the client's.
@export var replay_fingerprint_ticks: int = 120   # not in spec
## Room reserved up front for this much driving (grows by doubling after it).
@export var replay_reserve_s: float = 900.0   # not in spec
## Largest replay the client uploads (the server's `replays.max_bytes`, 4 MiB: a 6 h run).
@export var replay_max_bytes: int = 4194304
## Replays kept on the device waiting for their receipt or upload; the oldest is dropped.
@export var replay_keep_max: int = 10   # not in spec

@export_group("Replay verifier")
## Accept when the recomputed score is within this of the claimed one (spec: 3 %).
@export var verify_score_pct: float = 3.0
## Physics limits: the path may use up to this multiple of the car's measured lateral
## speed, lateral acceleration, yaw rate and longitudinal acceleration (task: x1.2).
@export var verify_limit_factor: float = 1.2
## Speed may exceed the boosted top speed by this much (quantization, overshoot).
@export var verify_speed_margin_pct: float = 2.0   # not in spec
## s and d between two samples must match the recorded velocities within this (a
## teleport, or an edited path that keeps its speeds).
@export var verify_path_tolerance_m: float = 0.25   # not in spec
## A recomputed hit matches a logged one within this long; a recomputed hit the log
## lacks is unreported.
@export var verify_hit_match_s: float = 0.35   # not in spec
## The client's scoring log must be reproduced this well (percent of scored events
## matched one to one by kind within verify_hit_match_s) once either side has at least
## verify_log_min_events: a replay from another world or a made-up log fails it.
@export var verify_log_match_pct: float = 80.0   # not in spec
@export var verify_log_min_events: int = 5   # not in spec
## Boost without meter: the verifier's own meter may run this far below empty.
@export var verify_boost_meter_slack: float = 0.1   # not in spec
## Lateral speed / acceleration after a hit's deflection are not judged for this long.
@export var verify_hit_grace_s: float = 0.5   # not in spec
## The capability table: the car is driven through full-lock maneuvers at speeds this
## far apart, for this long each (VerifierLimits).
@export var verify_calibration_step_mps: float = 5.0   # not in spec
@export var verify_calibration_s: float = 2.5   # not in spec


func ping_interval_usec() -> int:
	return roundi(ping_interval_s * 1.0e6)   # lint: allow-number s -> usec


func dead_timeout_usec() -> int:
	return roundi(dead_timeout_s * 1.0e6)   # lint: allow-number s -> usec


static func load_default() -> NetTuning:
	return load(PATH) as NetTuning
