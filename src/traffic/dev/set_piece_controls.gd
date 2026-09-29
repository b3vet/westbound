class_name SetPieceControls
extends DriveControls
# lint: not-sim dev-only sandbox controls (Node); they call the director's dev API
## Traffic sandbox: set-piece triggers and the intensity curve (WP6.2). Spec: Traffic →
## Traffic sandbox (debug scene) ("spawn controls"; "traffic quality gets tuned here");
## Traffic director (intensity waves, set pieces). docs/SET_PIECES.md.
##
## Buttons, top right under the sandbox's tab bar: one per implemented set piece (the
## next ahead batch gets it: TrafficDirector.force_set_piece, past the fog like any
## batch; the fairness checks still apply for a few batches), and WAVES, which shows the
## IntensityPlot panel (the curve around the player, blind windows, checkpoints, live
## pieces, the density numbers). Also the snap hook for set pieces (snap_run).
##
## The sandbox owns one (traffic_sandbox.gd adds it after its own UI); it reads the
## sandbox's current `director` and `car` every time (SEED makes a new director).

## Snap: the default distance to a forced piece at the capture, and how long to wait.
const SNAP_PIECE_DIST_M := 70.0
const SNAP_WAIT_S := 240.0
const TICKS_PER_SECOND := 120
const SNAP_STEP_TICKS := 30
const BUTTON_SIZE := Vector2(132.0, 48.0)
## The sandbox's tab bar height (TrafficSandbox.TAB_BUTTON.y).
const TAB_ROW_H := 56.0
## Kinds with a button (their data ids; WP6.3 adds its kinds here).
const PIECES: Array[StringName] = [&"truck_wall", &"rolling_roadblock"]
const LABELS: Array[String] = ["WALL", "BLOCK"]

## The traffic sandbox (duck-typed: `director`, `car`, advance_ticks()).
var sandbox: Node
var plot: IntensityPlot
var _waves_button: Button
var _piece_buttons: Array[Button] = []


func _ready() -> void:
	super()
	# Row 0 stays empty (the sandbox's tab bar is there): a spacer as tall as its buttons.
	var spacer := add_label(Corner.TOP_RIGHT, 0, 1.0)
	spacer.custom_minimum_size.y = TAB_ROW_H
	for k in PIECES.size():
		var id := PIECES[k]
		_piece_buttons.append(add_button(Corner.TOP_RIGHT, 1, LABELS[k], BUTTON_SIZE,
			func() -> void: trigger(id), true))
	_waves_button = add_button(Corner.TOP_RIGHT, 1, "WAVES", BUTTON_SIZE, toggle_plot, true)
	plot = IntensityPlot.new()
	plot.name = "IntensityPlot"
	plot.visible = false
	add_child(plot)
	_refresh()


func _process(_delta: float) -> void:
	if plot.visible and sandbox != null:
		plot.director = sandbox.get(&"director") as TrafficDirector
		var car: Node = sandbox.get(&"car")
		plot.player_s = (car.get(&"state") as VehicleState).s if car != null else 0.0
		plot.queue_redraw()


## The next ahead batch gets set piece `id`. False when it cannot (unknown, or one is live).
func trigger(id: StringName) -> bool:
	var dir := sandbox.get(&"director") as TrafficDirector if sandbox != null else null
	if dir == null:
		return false
	var ok := dir.force_set_piece(id)
	print("sandbox: set piece %s %s" % [id, "queued for the next batch" if ok else "refused (one is live?)"])
	return ok


func toggle_plot() -> void:
	plot.visible = not plot.visible
	_refresh()


func _refresh() -> void:
	DriveControls.set_text(_waves_button, "WAVES %s" % ("ON" if plot.visible else "off"))


## Snap hook (the sandbox's snap_setup calls it after its warm-up): set_piece=<id>
## forces that piece and runs the sandbox until it spawned (beyond the fog, as in play),
## then moves the player to piece_dist_m (default SNAP_PIECE_DIST_M) behind its rear,
## in its open lane, at its speed + piece_closing_kmh, and runs piece_after_s more (the
## roadblock's brake-light ripple starts at its warning). waves=true shows the plot.
func snap_run(args: Dictionary) -> void:
	if bool(args.get("waves", false)):
		plot.visible = true
		_refresh()
	if not args.has("set_piece"):
		return
	var id := StringName(str(args["set_piece"]))
	if not trigger(id):
		return
	var dir := sandbox.get(&"director") as TrafficDirector
	var car: Node = sandbox.get(&"car")
	var st := car.get(&"state") as VehicleState
	var inst := _wait_running(dir, id, roundi(float(args.get("piece_wait_s", SNAP_WAIT_S)) * float(TICKS_PER_SECOND)))
	if inst == null:
		var sp := dir.set_pieces
		print("snap: %s did not spawn (spawned %d, unplaced %d, uncommitted %d, unfit lanes/blind/checkpoint/road %d/%d/%d/%d, ended %d)" % [
			id, sp.spawned, sp.unplaced, sp.uncommitted, sp.unfit_lanes, sp.unfit_blind, sp.unfit_checkpoint,
			sp.unfit_road, sp.ended])
		return
	var road := dir.road
	var s := inst.s_rear - float(args.get("piece_dist_m", SNAP_PIECE_DIST_M))
	var lane := _open_lane(dir, inst)
	st.s = s
	st.d = road.lane_center_d(lane, s)
	st.v = inst.speed + Units.kmh_to_mps(float(args.get("piece_closing_kmh", 0.0)))
	sandbox.call(&"reset_car")
	var bot: Object = sandbox.get(&"bot")
	if bot != null:
		bot.set(&"v_target", st.v)
	sandbox.call(&"advance_ticks", roundi(float(args.get("piece_after_s", 0.3)) * float(TICKS_PER_SECOND)))
	print("snap: %s %.0f m ahead, %d vehicles, player in lane %d" % [id, inst.s_rear - st.s, inst.n, lane])


func _wait_running(dir: TrafficDirector, id: StringName, limit: int) -> SetPieceSource.Instance:
	var waited := 0
	while waited < limit:
		for inst in dir.set_pieces.instances:
			if inst.stage == SetPieceSource.Stage.RUNNING and inst.def.id == id:
				return inst
		sandbox.call(&"advance_ticks", SNAP_STEP_TICKS)
		waited += SNAP_STEP_TICKS
	return null


## A lane without a vehicle of the piece (the truck wall's open lane), else lane 1.
static func _open_lane(dir: TrafficDirector, inst: SetPieceSource.Instance) -> int:
	for lane in inst.lanes:
		var used := false
		for k in inst.n:
			used = used or dir.state.lane[inst.slot[k]] == lane
		if not used:
			return lane
	return mini(1, inst.lanes - 1)
