class_name NetTuning
extends Resource
## Client networking numbers: server URL, keepalive, clock sync, WebSocket buffers.
## Spec: multiplayer handoff → Networking protocol (Connection, Clock sync) and Tuning
## reference; docs/PROTOCOL.md §1. Saved as data/tuning/net.tres. WP N2.2.
## Until the orchestrator adds `Tuning.net`, load it with NetTuning.load_default().
##
## Protocol constants (frame cap, message cap, protocol version) are not tuning: they live
## in NetCodec and change only with a protocol version bump.

const PATH := "res://data/tuning/net.tres"

@export_group("Server")
@export var server_url: String = "wss://westbound.sipsakrandevu.com/ws"

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
