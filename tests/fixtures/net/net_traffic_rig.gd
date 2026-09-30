class_name NetTrafficRig
extends RefCounted
## Test rig for the client's network traffic (not a test suite: the runner skips
## tests/fixtures): a NetTrafficHarness on the loop (or another road) with a scripted
## player (TrafficBotPlayer) driving through the client's own view of traffic, and the
## per-run measurements the tests gate. Spec: multiplayer handoff → Testing (Netcode
## harness, client traffic corrector). docs/NET_TRAFFIC.md → Tests. WP N4.3.

const DT := 1.0 / 120.0

var tuning: Tuning
var road: RoadPath
var bot: TrafficBotPlayer
var harness: NetTrafficHarness
## Largest jump of a published car within the view beyond its own motion (m, per tick),
## measured independently of the source's own metric.
var jump_max_m: float = 0.0
## Seconds of client ticks run.
var t: float = 0.0
## Client ticks where a car moved sideways faster than LATERAL_SIGNAL_MPS with neither
## blinker nor hazards on.
var unsignaled_ticks: int = 0
## Shortest time a blinker was on before its car started moving sideways (cars that
## arrived already blinking excluded).
var blinker_lead_min_s: float = INF
## Where each car appeared relative to the player (m), every spawn.
var spawn_ds := PackedFloat64Array()
## The harness's truth error once the clock has settled (reset after TRUTH_SETTLE_S).
var truth_late: NetTrafficStats

const LATERAL_SIGNAL_MPS := 0.5
const TRUTH_SETTLE_S := 60.0
const _SIGNALS := TrafficState.FLAG_BLINKER_LEFT | TrafficState.FLAG_BLINKER_RIGHT | TrafficState.FLAG_HAZARD

var _prev_s := PackedFloat64Array()
var _prev_d := PackedFloat64Array()
var _prev_vid := PackedInt32Array()
var _blink_on := PackedFloat64Array()   # time the car's blinker came on (INF: off; -INF: at spawn)
var _moving := PackedByteArray()


## A rig on the loop, the bot `start_m` into lap 1 at `speed_kmh` (`base`: a tuning to use,
## e.g. a copy with other net numbers).
static func on_loop(seed_value: int, start_m: float, speed_kmh: float, weave: bool,
		mode: NetDelayLink.Mode = NetDelayLink.Mode.STREAM, with_loss: bool = true,
		base: Tuning = null) -> NetTrafficRig:
	var r := NetTrafficRig.new()
	r.tuning = base if base != null else Tuning.load_default()
	r.road = RunLoop.loop_road(r.tuning)
	var s := r.road.period_m() + start_m
	var bot_mode := TrafficBotPlayer.Mode.WEAVE
	r.bot = TrafficBotPlayer.new(r.road, 1, Units.kmh_to_mps(speed_kmh), bot_mode, seed_value, s)
	if not weave:
		r.bot.keep_lane()
	r.harness = NetTrafficHarness.new(r.tuning, r.road, r.bot.state, r.bot.length_m, r.bot.width_m,
		seed_value, mode, with_loss)
	return r


## Runs `seconds` of client ticks.
func run(seconds: float) -> void:
	var n := roundi(seconds / DT)
	var st := harness.client_state
	if _prev_s.is_empty():
		_prev_s.resize(st.capacity)
		_prev_d.resize(st.capacity)
		_prev_vid.resize(st.capacity)
		_blink_on.resize(st.capacity)
		_moving.resize(st.capacity)
	truth_late = harness.truth
	var vis_behind := tuning.net.traffic_visible_behind_m
	var vis_ahead := tuning.net.traffic_visible_ahead_m
	for k in n:
		bot.update(DT, st)
		harness.advance(DT)
		t += DT
		if t >= TRUTH_SETTLE_S and t - DT < TRUTH_SETTLE_S:
			harness.truth.reset()
		var p := bot.state.s
		for i in st.capacity:
			if st.active[i] == 0:
				_prev_vid[i] = 0
				continue
			var lit := (st.flags[i] & _SIGNALS) != 0
			if _prev_vid[i] == st.vehicle_id[i]:
				var ds := st.s[i] - p
				if ds >= -vis_behind and ds <= vis_ahead:
					var js := st.s[i] - _prev_s[i] - st.v[i] * DT
					var jd := st.d[i] - _prev_d[i] - st.v_lat[i] * DT
					jump_max_m = maxf(jump_max_m, sqrt(js * js + jd * jd))
				if lit and is_inf(_blink_on[i]) and _blink_on[i] > 0.0:
					_blink_on[i] = t
				elif not lit:
					_blink_on[i] = INF
				var lat := absf(st.d[i] - _prev_d[i]) / DT
				if lat > LATERAL_SIGNAL_MPS:
					if not lit:
						unsignaled_ticks += 1
					elif _moving[i] == 0 and not is_inf(_blink_on[i]):
						blinker_lead_min_s = minf(blinker_lead_min_s, t - _blink_on[i])
					_moving[i] = 1
				elif not lit:
					_moving[i] = 0
			else:
				spawn_ds.append(st.s[i] - p)
				_blink_on[i] = -INF if lit else INF
				_moving[i] = 0
			_prev_vid[i] = st.vehicle_id[i]
			_prev_s[i] = st.s[i]
			_prev_d[i] = st.d[i]


func stats() -> NetTrafficStats:
	return harness.source.stats


func summary() -> String:
	var a := harness.authority
	return ("%.0f s: %s | truth near: median %.3f p99 %.3f max %.3f | authority: %d frames %d bytes"
		+ " (%.0f B/s), spawns %d despawns %d intents %d cancels %d corrections %d, move mismatches %d;"
		+ " client active %d; clock rtt %.0f ms") % [
		t, stats().summary(), harness.truth.percentile(NetTrafficStats.P50),
		harness.truth.percentile(NetTrafficStats.P99), harness.truth.err_max, a.frames_sent, a.bytes_sent,
		float(a.bytes_sent) / maxf(t, 1.0), a.spawns_sent, a.despawns_sent, a.intents_sent, a.cancels_sent,
		a.corrections_sent, a.move_tick_mismatches, harness.client_state.count,
		harness.clock.best_rtt_s * NetClock.MS_PER_S]
