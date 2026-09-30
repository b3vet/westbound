extends Node
## Snap wrapper (dev, WP8.4 review): a Daily Drive run with a ghost car driving beside and
## ahead of the player, to review the ghost's look on both renderers, by day and by night.
## Spec: Core loop → Modes at launch ("a translucent ghost car"). docs/DAILY.md → Ghost car.
##
##   tools/snap.sh src/world/ghost/dev/ghost_preview.tscn --renderer=both --sweep=sky_t:0.3,0.8
##   tools/snap.sh src/world/ghost/dev/ghost_preview.tscn --ahead_m=25 --lane=1 --brake=true
##
## Args: --ahead_m= (how far ahead of the player the ghost starts, default AHEAD_M),
## --ghost_lane= (its lane; default the lane left of the player's), --brake=true (its brake
## lamps), --lights= (its headlamps; default on at night). The run's own args (--cam,
## --sky_t, --seed, --s, --speed_kmh, --car, --lane, --state, --hud) go to it, with
## --mode=daily and --bot=keep.

const RUN_KEYS: Array[String] = ["cam", "sky_t", "seed", "s", "speed_kmh", "car", "lane", "state", "hud"]
## Preview framing (dev only, not tuning).
const AHEAD_M := 14.0   # lint: allow-number dev preview framing
const GHOST_S := 120.0   # lint: allow-number dev preview length
const NIGHT_SKY_T := 0.5   # lint: allow-number the color script's sunset (preview default only)

@onready var _run: Run = $Run


func snap_setup(args: Dictionary) -> void:
	var run_args := {"mode": String(RunContext.MODE_DAILY), "bot": "keep", "hud": false}
	for key in RUN_KEYS:
		if args.has(key):
			run_args[key] = args[key]
	_run.snap_setup(run_args)
	var st := _run.car.state
	var road := _run.road
	var player_lane := road.lane_index_at(st.d, st.s)
	var lane := int(args.get("ghost_lane", maxi(player_lane - 1, 0) if player_lane > 0 else player_lane + 1))
	var night := float(args.get("sky_t", 0.0)) >= NIGHT_SKY_T
	var fl := 0
	if bool(args.get("lights", night)):
		fl |= DailyGhost.FLAG_LIGHTS
	if bool(args.get("brake", false)):
		fl |= DailyGhost.FLAG_BRAKE
	var hz := _run.tuning.vehicle.physics_tick_hz
	var every := _run.daily.tuning.ghost_sample_ticks(hz)
	var rec := DailyGhostRecorder.new()
	rec.begin(_run.daily.date, _run.current_seed, String(_run.car.car.id), hz, every, 64)
	var s0 := st.s + float(args.get("ahead_m", AHEAD_M))
	var v := maxf(st.v, 1.0)
	for k in range(1, roundi(GHOST_S * float(hz)) + 1):
		var s := s0 + v * float(k) / float(hz)
		rec.step(k, s, road.lane_center_d(lane, s), 0.0, v, fl, false)
	_run.daily.set_ghost(rec.finish(0))
	_run.daily.update_view()
