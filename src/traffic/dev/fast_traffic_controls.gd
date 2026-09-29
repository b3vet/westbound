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
const TICKS_PER_SECOND := 120

## The traffic sandbox (duck-typed: `sim`, `car`, `registry`, `tuning`, `traffic_seed`,
## `overlay`, reseed(), spawn_vehicle(), advance_ticks()).
var sandbox: Node
var fast_scale: float = 1.0
var _fast_button: Button
var _base_director: DirectorTuning


func _ready() -> void:
	super()
	for k in ROWS_ABOVE_H.size():
		var spacer := add_label(Corner.TOP_RIGHT, k, 1.0)
		spacer.custom_minimum_size.y = ROWS_ABOVE_H[k]
	var row := ROWS_ABOVE_H.size()
	_fast_button = add_button(Corner.TOP_RIGHT, row, "", BUTTON_SIZE, cycle_fast_scale, true)
	add_button(Corner.TOP_RIGHT, row, "RACER", BUTTON_SIZE, func() -> void: spawn_racer(), true)
	_refresh()


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


## Snap hook (the sandbox's snap_setup calls it after its warm-up): racer=true spawns a
## racer behind the player and runs until it is SNAP_AHEAD_M ahead (a racer passing);
## fast=K sets the fast scale first.
func snap_run(args: Dictionary) -> void:
	if args.has("fast"):
		set_fast_scale(float(args["fast"]))
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
