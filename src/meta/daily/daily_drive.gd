class_name DailyDrive
extends Node
## Daily Drive's ghost on the run: records every Daily run at 20 Hz, keeps the day's best
## on the device, and plays it back as a translucent ghost car on later attempts. Spec:
## Core loop → Modes at launch ("Daily Drive: the seed is a hash of the UTC date ... Your
## best daily run is recorded and shown as a translucent ghost car on later attempts (the
## car's s, d and heading sampled at 20 Hz)"), Save data. WP8.4; docs/DAILY.md.
##
## The Run owns one (`Run.daily`) and calls it at four points; it never drives gameplay
## (Architecture rule 8: the ghost has no collisions and no scoring effect, it only reads
## the run's state):
##   on_run_started()      _start_run (not the title's world): a Daily run records and
##                         loads the date's best ghost; any other mode turns it off
##   after_tick(running)   Run.tick, after the RUNNING tick (running) or a CRASH tick:
##                         the playback clock (RUNNING ticks since GO, then the crash),
##                         the recorder (RUNNING ticks only)
##   update_view()         Run.frame: the ghost's pose (DailyGhostPlayback, road space)
##                         mapped onto the player's road (path_for: forks) and placed in
##                         render space, lamps from its flags
##   on_run_over(results)  Run._show_results, before the save is written: the ghost is
##                         kept when it beats the date's best (DailyGhostStore)
## after_tick and update_view allocate nothing.

## Off: nothing is written. bind() takes the save's (off under tests and tools); the Run
## also calls on_run_over only when it records bests.
var save_enabled: bool = true
var tuning: DailyTuning
var store: DailyGhostStore
var recorder := DailyGhostRecorder.new()
var playback := DailyGhostPlayback.new()
var ghost_car: GhostCar
var run: Run
## The Daily run's date ("YYYY-MM-DD"); "" outside Daily Drive.
var date: String = ""
## A Daily run is on (recording, maybe playing a ghost).
var active: bool = false
## The last run's ghost was kept as the date's best (results, tests).
var saved: bool = false
## Playback clock: ticks since GO (RUNNING, then CRASH).
var play_k: int = 0

var _rec_k: int = 0
var _last_resets: int = 0
var _last_resolved: int = 0
var _pose := DailyGhostPlayback.Pose.new()
var _smp := RoadSample.new()
var _shift_d: float = 0.0


func _init() -> void:
	name = "DailyDrive"


## Once, from Run._ready.
func bind(r: Run) -> void:
	run = r
	save_enabled = Save.persistent
	if tuning == null:
		tuning = DailyTuning.resolve()
	if store == null:
		store = DailyGhostStore.new(Save.section(DailyGhostStore.SECTION), tuning)
	if ghost_car == null:
		ghost_car = GhostCar.new()
		add_child(ghost_car)


## A run started (not the title's): Daily records and loads the date's ghost.
func on_run_started() -> void:
	recorder.cancel()
	playback.setup(null)
	play_k = 0
	_rec_k = 0
	saved = false
	ghost_car.hide_ghost()
	active = run.mode == RunContext.MODE_DAILY and not run.is_loop()
	if not active:
		date = ""
		return
	date = run.active_daily_date
	var tick_hz := run.tuning.vehicle.physics_tick_hz
	var every := tuning.ghost_sample_ticks(tick_hz)
	recorder.begin(date, run.current_seed, String(run.car.car.id), tick_hz, every,
		ceili(tuning.ghost_reserve_s * float(tick_hz) / float(every)))
	_last_resets = run._resets
	_last_resolved = run.forks.resolved_count
	if tuning.ghost_enabled:
		var g := store.load_ghost(date)
		if g != null and g.seed_value == run.current_seed:
			set_ghost(g)


## Plays `g` from GO (the stored best; previews and tests hand one in).
func set_ghost(g: DailyGhost) -> void:
	playback.setup(g)
	if g != null:
		ghost_car.use_car(_car_def(g.car))


## After a tick: `running` = it was a RUNNING tick (else CRASH). Allocation-free.
func after_tick(running: bool) -> void:
	if not active:
		return
	play_k += 1
	if not running or not recorder.recording:
		return
	_rec_k += 1
	var f := run.forks
	if f.resolved_count != _last_resolved:
		_last_resolved = f.resolved_count
		if f.active >= 0 and f.active < f.choices.size():
			recorder.note_fork(_rec_k, f.active, f.choices[f.active])
	var reset := run._resets != _last_resets
	_last_resets = run._resets
	var st := run.car.state
	var fl := 0
	if run.car.visual != null and run.car.visual.brake_lights_on:
		fl |= DailyGhost.FLAG_BRAKE
	if run._headlights:
		fl |= DailyGhost.FLAG_LIGHTS
	if st.boost_active:
		fl |= DailyGhost.FLAG_BOOST
	recorder.step(_rec_k, st.s, st.d, st.yaw, st.v, fl, reset)


## Frame rate: the ghost's pose, or hidden. Allocation-free.
func update_view() -> void:
	if not active or not tuning.ghost_enabled or not playback.has_ghost() or run.state == Game.MENU:
		ghost_car.hide_ghost()
		return
	if not playback.pose_into(float(play_k), _pose):
		ghost_car.hide_ghost()
		return
	var path := path_for(_pose.forks_done)
	var player_s := run.car.state.s
	if path == null or _pose.s < player_s - tuning.ghost_view_behind_m \
			or _pose.s > player_s + tuning.ghost_view_ahead_m or _pose.s > _path_end(path):
		ghost_car.hide_ghost()
		return
	path.sample_into(_pose.s, _smp)
	var o := run.origin
	var b := Basis(Vector3.UP, _smp.godot_yaw(_pose.yaw)) * Basis(Vector3.RIGHT, VehiclePhysics.surface_pitch(_smp))
	var xf := Transform3D(b, _smp.local_point(_pose.d + _shift_d, o.origin_x, o.origin_y, o.origin_z))
	ghost_car.show_at(xf, (_pose.flags & DailyGhost.FLAG_BRAKE) != 0, (_pose.flags & DailyGhost.FLAG_LIGHTS) != 0)


## The run ended: keeps the ghost when it beats the date's best. Before the save is written.
func on_run_over(results: Dictionary) -> void:
	if not active:
		return
	var g := recorder.finish(int(results.get(RunStats.SCORE, 0)))
	saved = false
	if g == null or not save_enabled or not tuning.ghost_enabled or results.get(RunWarmup.RESULT_KEY, false):
		return
	saved = store.offer(g, DailyGhostStore.today_utc())
	if saved:
		Save.request_save()


## The road the ghost drives on once `forks_done` of its forks resolved, or null when it
## took a branch the player did not (or one the player has not reached, beyond the next).
## _shift_d gets the d offset into that road's frame: a fork the player took to the right
## and the ghost has not reached yet moved the road's d frame by the fork's shift.
func path_for(forks_done: int) -> RoadPath:
	_shift_d = 0.0
	var f := run.forks
	var g := playback.ghost
	var path: RoadPath = run.road
	for j in forks_done:
		var fi := int(g.fork_index[j])
		var side := int(g.fork_side[j])
		if fi < 0 or fi >= f.choices.size():
			return null
		var pc := f.choices[fi]
		if pc == ForkPlan.UNRESOLVED:
			# The player is still before this split: the main road is its left branch,
			# the candidate its right one.
			if fi != f.active or j != forks_done - 1:
				return null
			if side == ForkPlan.RIGHT:
				if f.candidate == null or not f.ready:
					return null
				path = f.candidate
		elif pc != side:
			return null
	for fi in f.choices.size():
		if f.choices[fi] == ForkPlan.RIGHT and not _ghost_took(fi, forks_done) and fi < f._shifts.size():
			_shift_d -= f._shifts[fi]
	return path


func _ghost_took(fork: int, forks_done: int) -> bool:
	var g := playback.ghost
	for j in forks_done:
		if int(g.fork_index[j]) == fork:
			return true
	return false


func _path_end(path: RoadPath) -> float:
	var p := path as ProceduralRoadPath
	return p.table_end() if p != null else path.length_generated()


## The ghost's car by id (Run.CAR_PATHS), else the player's.
func _car_def(id: String) -> CarDef:
	for p in Run.CAR_PATHS:
		if p.get_file().get_basename() == id:
			return load(p) as CarDef
	return run.car.car
