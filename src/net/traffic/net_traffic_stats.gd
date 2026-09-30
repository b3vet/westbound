class_name NetTrafficStats
extends RefCounted
# lint: sim
## Counters and distributions of the client's network traffic: what the dev HUD shows and
## the tests and soaks gate. Spec: multiplayer handoff → Client network traffic ("Dev HUD
## adds network metrics: average and maximum correction size, late intents per minute"),
## Testing → Netcode harness (median correction < 0.15 m, 99th percentile < 0.6 m, late
## intents < 1 per 10 minutes). docs/NET_TRAFFIC.md → Metrics. WP N4.3.
##
## Correction sizes (the position error |(e_s, e_d)| at the correction's tick) go into a
## fixed histogram (HIST_BIN_M bins up to HIST_MAX_M, one overflow bin), for every car and
## for cars within the near radius, so percentiles cost no allocation. Rates (per second,
## per minute) come from `rate()`: the counters are sampled once per second into a ring of
## `window` seconds. Allocation-free after _init.

const HIST_BIN_M := 0.005   # lint: allow-number histogram resolution (5 mm), a metric not tuning
const HIST_BINS := 400
const P50 := 0.5
const P99 := 0.99   # lint: allow-number the 99th percentile (the spec's bound)
## What rate() can measure.
enum Counter { CORRECTIONS, BYTES, LATE_INTENTS, INTENTS, COUNT }

var corrections: int = 0          ## applied corrections
var corrections_near: int = 0     ## ... of cars within traffic_correction_near_m
var err_sum: float = 0.0          ## m, sum of correction sizes
var err_max: float = 0.0
var err_near_sum: float = 0.0
var err_near_max: float = 0.0
var err_lat_max: float = 0.0      ## m, the largest lateral part
var blends_small: int = 0         ## corrections eased over blend_small_s
var blends_medium: int = 0        ## ... over blend_medium_s
var snaps: int = 0                ## large errors snapped out of view (logged)
var large_in_view: int = 0        ## large errors in view, slid out at the capped speed
var teleports: int = 0            ## visible teleports (published jumps in view; gate 0)
var teleport_max_m: float = 0.0   ## m, the largest per-tick jump beyond the car's motion in view
var intents: int = 0
var late_intents: int = 0         ## arrived after move start - late_min_blinker_s
var very_late_intents: int = 0    ## arrived after the move start itself
var cancels: int = 0
var late_cancels: int = 0         ## arrived after the car had started moving
var unsignaled_lateral: int = 0   ## unexplained lateral corrections shown with a blinker
var spawns: int = 0
var despawns: int = 0
var stale_despawns: int = 0       ## dropped after traffic_stale_car_s of silence
var unknown_car: int = 0          ## a message for a car id the client does not know
var old_corrections: int = 0      ## older than the last applied one for the car (reordered)
var no_history: int = 0           ## older than the history: applied by extrapolation
var dropped_full: int = 0         ## spawns refused: TrafficState full
var bad_values: int = 0           ## vehicle / profile / lane outside the client's tables
var frames: int = 0
var frame_errors: int = 0
var bytes: int = 0                ## protocol bytes of applied frames

var _hist := PackedInt32Array()
var _hist_near := PackedInt32Array()
var _ring := PackedFloat64Array()   # window x Counter.COUNT cumulative values, per second
var _ring_t := PackedFloat64Array() # the time of each sample
var _ring_n: int = 0
var _window: int = 1
var _next_sample_t: float = 0.0


func _init(window_s: float) -> void:
	_hist.resize(HIST_BINS + 1)
	_hist_near.resize(HIST_BINS + 1)
	_window = maxi(roundi(window_s), 1) + 1
	_ring.resize(_window * Counter.COUNT)
	_ring_t.resize(_window)
	reset()


func reset() -> void:
	corrections = 0
	corrections_near = 0
	err_sum = 0.0
	err_max = 0.0
	err_near_sum = 0.0
	err_near_max = 0.0
	err_lat_max = 0.0
	blends_small = 0
	blends_medium = 0
	snaps = 0
	large_in_view = 0
	teleports = 0
	teleport_max_m = 0.0
	intents = 0
	late_intents = 0
	very_late_intents = 0
	cancels = 0
	late_cancels = 0
	unsignaled_lateral = 0
	spawns = 0
	despawns = 0
	stale_despawns = 0
	unknown_car = 0
	old_corrections = 0
	no_history = 0
	dropped_full = 0
	bad_values = 0
	frames = 0
	frame_errors = 0
	bytes = 0
	_hist.fill(0)
	_hist_near.fill(0)
	_ring.fill(0.0)
	_ring_t.fill(0.0)
	_ring_n = 0
	_next_sample_t = 0.0


## One applied correction of size `err_m` (lateral part `lat_m`), `near` = within the
## near radius of the player.
func add_correction(err_m: float, lat_m: float, near: bool) -> void:
	corrections += 1
	err_sum += err_m
	err_max = maxf(err_max, err_m)
	err_lat_max = maxf(err_lat_max, absf(lat_m))
	var b := mini(floori(err_m / HIST_BIN_M), HIST_BINS)
	_hist[b] += 1
	if near:
		corrections_near += 1
		err_near_sum += err_m
		err_near_max = maxf(err_near_max, err_m)
		_hist_near[b] += 1


func mean_error() -> float:
	return err_sum / float(corrections) if corrections > 0 else 0.0


func mean_error_near() -> float:
	return err_near_sum / float(corrections_near) if corrections_near > 0 else 0.0


## The q-quantile (0..1) of the correction sizes (the upper edge of its bin; INF when it
## falls in the overflow bin), of every car or of the near ones.
func percentile(q: float, near_only: bool = false) -> float:
	var h := _hist_near if near_only else _hist
	var total := corrections_near if near_only else corrections
	if total == 0:
		return 0.0
	var want := ceili(q * float(total))
	var acc := 0
	for b in HIST_BINS + 1:
		acc += h[b]
		if acc >= want:
			return INF if b == HIST_BINS else float(b + 1) * HIST_BIN_M
	return INF


## Samples the counters once per second of `now_s` (server time in seconds). Cheap; call
## every tick.
func sample(now_s: float) -> void:
	if now_s < _next_sample_t:
		return
	_next_sample_t = floorf(now_s) + 1.0
	var k := _ring_n % _window
	_ring_t[k] = now_s
	var o := k * Counter.COUNT
	_ring[o + Counter.CORRECTIONS] = float(corrections)
	_ring[o + Counter.BYTES] = float(bytes)
	_ring[o + Counter.LATE_INTENTS] = float(late_intents)
	_ring[o + Counter.INTENTS] = float(intents)
	_ring_n += 1


## Per-second rate of `counter` over the sampled window (0 until two samples).
func rate(counter: Counter) -> float:
	if _ring_n < 2:
		return 0.0
	var newest := (_ring_n - 1) % _window
	var oldest := (_ring_n - mini(_ring_n, _window)) % _window
	var span := _ring_t[newest] - _ring_t[oldest]
	if span <= 0.0:
		return 0.0
	return (_ring[newest * Counter.COUNT + counter] - _ring[oldest * Counter.COUNT + counter]) / span


## Dev HUD / DevStats keys (reported by `report_dev_stats`, read by the dev HUD's net rows).
const DEV_CORR_PER_S := &"net_traffic_corr_per_s"
const DEV_ERR_MEAN_M := &"net_traffic_err_mean_m"
const DEV_ERR_MAX_M := &"net_traffic_err_max_m"
const DEV_ERR_P99_M := &"net_traffic_err_p99_m"
const DEV_LATE_PER_MIN := &"net_traffic_late_per_min"
const DEV_BYTES_PER_S := &"net_traffic_bytes_per_s"
const DEV_TELEPORTS := &"net_traffic_teleports"
const DEV_SNAPS := &"net_traffic_snaps"


## Writes the dev HUD's numbers into DevStats (a Node adapter or the sandbox calls this a
## few times per second; DevStats is a static registry, not an autoload).
func report_dev_stats() -> void:
	DevStats.report(DEV_CORR_PER_S, rate(Counter.CORRECTIONS))
	DevStats.report(DEV_ERR_MEAN_M, mean_error())
	DevStats.report(DEV_ERR_MAX_M, err_max)
	DevStats.report(DEV_ERR_P99_M, percentile(P99))
	DevStats.report(DEV_LATE_PER_MIN, rate(Counter.LATE_INTENTS) * Units.S_PER_MIN)
	DevStats.report(DEV_BYTES_PER_S, rate(Counter.BYTES))
	DevStats.report(DEV_TELEPORTS, teleports)
	DevStats.report(DEV_SNAPS, snaps)


## One line for logs and soaks.
func summary() -> String:
	return ("corrections %d (near %d): mean %.3f m, median %.3f, p99 %.3f, max %.3f (lateral %.3f);"
		+ " near mean %.3f, p99 %.3f, max %.3f; blends %d/%d, snaps %d, large in view %d,"
		+ " teleports %d (max %.3f m); intents %d, late %d, very late %d, cancels %d (late %d),"
		+ " unsignaled lateral %d; spawns %d, despawns %d, stale %d, unknown %d, reordered %d,"
		+ " no history %d, full %d, bad %d; frames %d (%d errors), %d bytes") % [
		corrections, corrections_near, mean_error(), percentile(P50), percentile(P99), err_max,
		err_lat_max, mean_error_near(), percentile(P99, true), err_near_max, blends_small,
		blends_medium, snaps, large_in_view, teleports, teleport_max_m, intents, late_intents,
		very_late_intents, cancels, late_cancels, unsignaled_lateral, spawns, despawns,
		stale_despawns, unknown_car, old_corrections, no_history, dropped_full, bad_values, frames,
		frame_errors, bytes]
