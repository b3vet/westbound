class_name FastTrafficControls
extends DriveControls
# lint: not-sim dev-only sandbox controls (Node); they swap the sandbox's tuning and spawn through its API
## Traffic sandbox: the fast traffic of plan D15 (WP6.6; owner, M5 playtest: "a variety
## of fast cars"). Spec: Traffic → Traffic sandbox (debug scene) ("spawn controls";
## "traffic quality gets tuned here"); Traffic → Driver types (+ Racer, plan D15).
##
## Buttons, top right under the sandbox's tab bar and WP6.2's set-piece row:
##   FAST xK  scales the fast shares (aggressive and racer, DirectorTuning) by
##            FAST_SCALES; the sandbox re-seeds with a private copy of the tuning (the
##            shared default is never touched)
##   RACER    spawns a racer behind the player, one lane left of it when there is one,
##            and selects it (MOBIL panel, labels)
## and on the row below:
##   ARR ON/OFF  the director's racer arrivals from behind (plan D17, WP6.7) on / off;
##            kept across re-seeds
##   ARRIVE   the next arrival is due now (it still needs a lane that fits); the arrival
##            is selected when it spawns
## The stats panel's "racers" line and the dev report's "racers" line
## (DevReport.racers_line) count racers passing the player and overtaken by it.
## The stats panel's "speeds" line and the dev report's "traffic" line show the live
## speed distribution (DevReport.traffic_line). Also the snap hook (snap_run: racer=true).
##
## The sandbox owns one (traffic_sandbox.gd adds it after its own UI); it reads the
## sandbox's current `sim`, `car`, `registry` and `tuning` every time.

const FAST_SCALES: Array[float] = [1.0, 1.5, 2.0, 0.0]
const BUTTON_SIZE := Vector2(132.0, 48.0)
## Rows above this one: the sandbox's tab bar (TrafficSandbox.TAB_BUTTON.y) and WP6.2's
## set-piece row (SetPieceControls.BUTTON_SIZE.y).
const ROWS_ABOVE_H: Array[float] = [56.0, 48.0]
## Snap: run until the racer is this far ahead of the player (center to center), at most
## SNAP_WAIT_S.
const SNAP_AHEAD_M := 6.0
const SNAP_WAIT_S := 30.0
const SNAP_STEP_TICKS := 6
## Snap (arrival=true, WP6.7): run until the arrival is this far ahead of the player
## (center to center: passing alongside), at most ARRIVAL_WAIT_S.
const ARRIVAL_SNAP_AHEAD_M := 2.0
const ARRIVAL_WAIT_S := 90.0
const TICKS_PER_SECOND := 120

## The traffic sandbox (duck-typed: `sim`, `car`, `registry`, `tuning`, `traffic_seed`,
## `overlay`, reseed(), spawn_vehicle(), advance_ticks()).
var sandbox: Node
var fast_scale: float = 1.0
## Racer arrivals (WP6.7) on the sandbox's director, re-applied after every re-seed.
var arrivals_on: bool = true
var _fast_button: Button
var _arr_button: Button
var _arrivals_seen: int = 0
var _base_director: DirectorTuning


func _ready() -> void:
	super()
	for k in ROWS_ABOVE_H.size():
		var spacer := add_label(Corner.TOP_RIGHT, k, 1.0)
		spacer.custom_minimum_size.y = ROWS_ABOVE_H[k]
	var row := ROWS_ABOVE_H.size()
	_fast_button = add_button(Corner.TOP_RIGHT, row, "", BUTTON_SIZE, cycle_fast_scale, true)
	add_button(Corner.TOP_RIGHT, row, "RACER", BUTTON_SIZE, func() -> void: spawn_racer(), true)
	# Racer arrivals (WP6.7) on the row below, so the rows stay narrow on phones.
	_arr_button = add_button(Corner.TOP_RIGHT, row + 1, "", BUTTON_SIZE, func() -> void: set_arrivals(not arrivals_on), true)
	add_button(Corner.TOP_RIGHT, row + 1, "ARRIVE", BUTTON_SIZE, func() -> void: force_arrival(), true)
	_refresh()


func _process(_delta: float) -> void:
	# Select a new arrival (the ARRIVE button, or the director's own process).
	var dir := sandbox.get(&"director") as TrafficDirector
	if dir == null or dir.racer_arrivals == _arrivals_seen:
		return
	_arrivals_seen = dir.racer_arrivals
	var overlay := sandbox.get(&"overlay") as Node
	if overlay != null and dir.last_arrival_slot >= 0:
		overlay.set(&"selected_slot", dir.last_arrival_slot)


## Racer arrivals from behind (WP6.7) on / off on the sandbox's director.
func set_arrivals(on: bool) -> void:
	arrivals_on = on
	apply_to(sandbox.get(&"director") as TrafficDirector)
	print("sandbox: racer arrivals %s" % ("on" if on else "off"))
	_refresh()


## The sandbox calls this for every new director (re-seed).
func apply_to(dir: TrafficDirector) -> void:
	if dir == null:
		return
	dir.racer_arrivals_enabled = arrivals_on
	_arrivals_seen = dir.racer_arrivals


## The director's next racer arrival is due now (turns arrivals on).
func force_arrival() -> void:
	if not arrivals_on:
		set_arrivals(true)
	var dir := sandbox.get(&"director") as TrafficDirector
	if dir != null:
		dir.force_racer_arrival()


## Next FAST_SCALES entry: scales the aggressive and racer shares and re-seeds.
func cycle_fast_scale() -> void:
	var i := FAST_SCALES.find(fast_scale)
	set_fast_scale(FAST_SCALES[(i + 1) % FAST_SCALES.size()])


## The sandbox's traffic with the fast shares x `k` (a private copy of the tuning; the
## sandbox re-seeds so the new director reads it).
func set_fast_scale(k: float) -> void:
	fast_scale = k
	var base := sandbox.get(&"tuning") as Tuning
	if _base_director == null:
		_base_director = base.director
	var t := base.duplicate() as Tuning
	var d := _base_director.duplicate() as DirectorTuning
	d.aggressive_share_first_pct = _base_director.aggressive_share_first_pct * k
	d.aggressive_share_last_pct = _base_director.aggressive_share_last_pct * k
	d.racer_share_first_pct = _base_director.racer_share_first_pct * k
	d.racer_share_last_pct = _base_director.racer_share_last_pct * k
	t.director = d
	sandbox.set(&"tuning", t)
	sandbox.call(&"reseed", int(sandbox.get(&"traffic_seed")))
	print("sandbox: fast shares x%.1f (leg 1: aggressive %.0f%%, racer %.0f%%)" % [k,
		d.aggressive_share_first_pct, d.racer_share_first_pct])
	_refresh()


## Spawns a racer behind the player (one lane left of it, else its lane) and selects it.
## Returns the slot, or -1.
func spawn_racer() -> int:
	var reg := sandbox.get(&"registry") as TrafficRegistry
	var t := sandbox.get(&"tuning") as Tuning
	var pid := reg.profile_index(t.traffic.spawn_racer_profile_id)
	if pid < 0:
		return -1
	var sim := sandbox.get(&"sim") as TrafficSim
	var st := (sandbox.get(&"car") as Node).get(&"state") as VehicleState
	var lane := maxi(sim.road.lane_index_at(st.d, st.s) - 1, 0)
	var slot: int = sandbox.call(&"spawn_vehicle", pid, 0, lane, false)
	var overlay := sandbox.get(&"overlay") as Node
	if slot >= 0 and overlay != null:
		overlay.set(&"selected_slot", slot)
	print("sandbox: racer %s in lane %d" % ["slot %d" % slot if slot >= 0 else "not placed", lane])
	return slot


func _refresh() -> void:
	DriveControls.set_text(_fast_button, "FAST x%.1f" % fast_scale)
	if _arr_button != null:
		DriveControls.set_text(_arr_button, "ARR ON" if arrivals_on else "ARR OFF")


## Snap hook (the sandbox's snap_setup calls it after its warm-up): racer=true spawns a
## racer behind the player and runs until it is SNAP_AHEAD_M ahead (a racer passing);
## fast=K sets the fast scale first; arrival=true: snap_arrival.
func snap_run(args: Dictionary) -> void:
	if args.has("fast"):
		set_fast_scale(float(args["fast"]))
	if bool(args.get("arrival", false)):
		snap_arrival(args)
		return
	if not bool(args.get("racer", false)):
		return
	var slot := spawn_racer()
	if slot < 0:
		return
	var sim := sandbox.get(&"sim") as TrafficSim
	var st := (sandbox.get(&"car") as Node).get(&"state") as VehicleState
	var ahead := float(args.get("racer_ahead_m", SNAP_AHEAD_M))
	var ticks := 0
	while sim.state.active[slot] == 1 and sim.state.s[slot] - st.s < ahead \
			and ticks < roundi(SNAP_WAIT_S * TICKS_PER_SECOND):
		sandbox.call(&"advance_ticks", SNAP_STEP_TICKS)
		ticks += SNAP_STEP_TICKS
	print("snap: racer slot %d at %+.1f m, %.0f km/h (player %.0f km/h), after %.1f s" % [slot,
		sim.state.s[slot] - st.s, Units.mps_to_kmh(sim.state.v[slot]), Units.mps_to_kmh(st.v),
		float(ticks) / TICKS_PER_SECOND])


## Snap (WP6.7): a racer arrival passing the player. The traffic near the player is
## cleared (arrival_clear=false keeps it), the director's next arrival is made due
## (again every second until one fits), and the sandbox runs until the arrival is
## arrival_ahead_m (ARRIVAL_SNAP_AHEAD_M) ahead of the player, at most ARRIVAL_WAIT_S.
## Use with driver=keep speed_kmh=200 (the player holding 200 km/h).
func snap_arrival(args: Dictionary) -> void:
	if bool(args.get("arrival_clear", true)):
		sandbox.call(&"clear_traffic")
	set_arrivals(true)
	var dir := sandbox.get(&"director") as TrafficDirector
	var sim := sandbox.get(&"sim") as TrafficSim
	var st := (sandbox.get(&"car") as Node).get(&"state") as VehicleState
	var ahead := float(args.get("arrival_ahead_m", ARRIVAL_SNAP_AHEAD_M))
	var n0 := dir.racer_arrivals
	var slot := -1
	var vid := -1
	var ticks := 0
	while ticks < roundi(ARRIVAL_WAIT_S * TICKS_PER_SECOND):
		if slot < 0 and ticks % TICKS_PER_SECOND == 0:
			dir.force_racer_arrival()
		sandbox.call(&"advance_ticks", SNAP_STEP_TICKS)
		ticks += SNAP_STEP_TICKS
		if slot < 0 and dir.racer_arrivals > n0:
			slot = dir.last_arrival_slot
			vid = sim.state.vehicle_id[slot]
		if slot >= 0 and (sim.state.active[slot] == 0 or sim.state.vehicle_id[slot] != vid):
			slot = -1   # gone (it should not): wait for the next
			n0 = dir.racer_arrivals
		elif slot >= 0 and sim.state.s[slot] - st.s >= ahead:
			break
	var overlay := sandbox.get(&"overlay") as Node
	if slot >= 0 and overlay != null:
		overlay.set(&"selected_slot", slot)
	print("snap: arrival slot %d at %+.1f m, %.0f km/h (desired %.0f), player %.0f km/h, after %.1f s; %s" % [
		slot, sim.state.s[slot] - st.s if slot >= 0 else NAN, Units.mps_to_kmh(sim.state.v[slot]) if slot >= 0 else NAN,
		Units.mps_to_kmh(sim.state.v0[slot]) if slot >= 0 else NAN, Units.mps_to_kmh(st.v),
		float(ticks) / TICKS_PER_SECOND, DevReport.racers_line(dir)])
