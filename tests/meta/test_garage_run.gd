extends WBTest
## WP8.2: the garage's selection and the run. The title's attract car and every run from
## the title drive the selected car in its paint and rims; changing it in the garage
## swaps the attract car; the results carry the car id the leaderboards submit; the
## results' GARAGE opens the garage over the title; direct boots, tests and tools keep
## car_index; `?car=` resolves an index or an id; and the look never changes the run
## (identical traces for the same car in any paint and rims). Spec: Garage and
## progression; UI → Screens (Title: "the attract camera drives the selected car";
## Results: Retry and Garage); Architecture rule 5 (determinism). docs/GARAGE.md.

const RUN_SCENE := preload("res://src/run/run.tscn")
const SEED := 20260929
const IOS_ID := 1_893_457_201
const FRAME_S := 1.0 / 60.0
const TICKS_PER_FRAME := 2
const TRACE_S := 6.0
const BOT_SPEED_MPS := 52.0
const BOT_SEED := 11

var t: Tuning
var cat: GarageCatalog
var _nodes: Array[Node] = []
var _saved: Dictionary


func before_all() -> void:
	t = Tuning.load_default()
	cat = Garage.catalog()


func before_each() -> void:
	Settings.reset_to_defaults()
	_saved = Save.data.duplicate(true)
	Save.data = SaveMigrations.fresh()


func after_each() -> void:
	tree.paused = false
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	await tree.process_frame
	Save.data = _saved
	Save.dirty = false
	Settings.reset_to_defaults()
	Engine.time_scale = 1.0


func _run(title: bool, car_index: int = 0, look: CarLook = null) -> Run:
	var r := RUN_SCENE.instantiate() as Run
	r.run_seed = SEED
	r.manual_ticks = true
	r.crash_cinematic = false
	r.record_best = false
	r.title_on_boot = title
	r.car_index = car_index
	r.car_look = look
	tree.root.add_child(r)
	_nodes.append(r)
	r.screens.persist_settings = false
	r.title.persist_settings = false
	r.title.set_screen(Rect2(0.0, 0.0, 1280.0, 720.0), Rect2(0.0, 0.0, 1280.0, 720.0))
	return r


func _ticks(r: Run, n: int) -> void:
	for i in n:
		r.tick()
		if i % TICKS_PER_FRAME == TICKS_PER_FRAME - 1:
			r.frame(FRAME_S)


func _tap(c: Control) -> void:
	var p := tree.root.get_final_transform() * c.get_global_rect().get_center()
	for down: bool in [true, false]:
		var ev := InputEventScreenTouch.new()
		ev.index = IOS_ID
		ev.position = p
		ev.pressed = down
		Input.parse_input_event(ev)
		Input.flush_buffered_events()


func _crash_to_results(r: Run) -> void:
	if r.state == Game.COUNTDOWN:
		r.go()
	_ticks(r, roundi(0.5 * float(t.vehicle.physics_tick_hz)))
	r.lives.lives = 1
	r.force_hit(HitDetection.HIT_BARRIER, -1, 1)
	_ticks(r, TICKS_PER_FRAME)
	r.skip()
	r.screens.results_screen.accept_input_now()


## Everything unlocked, then `slot_id` selected in the last paint and rims.
func _select(slot_id: StringName) -> Array:
	var p := Garage.profile()
	p.stats[MetaProfile.XP] = Progression.xp_to_reach(t.progression.max_level, t.progression)
	p.stats[MetaProfile.BEST_LEG] = t.progression.unlock_leg_milestone
	p.refresh_unlocks()
	var paint := cat.paints[cat.paints.size() - 1]
	var rim := cat.rims[cat.rims.size() - 1]
	check(p.select_car(slot_id), "select %s" % slot_id)
	check(p.select_paint(slot_id, paint.id))
	check(p.select_rim(slot_id, rim.id))
	return [paint, rim]


func test_the_selection_drives_the_title_and_the_run() -> void:
	var picked := _select(&"night_viper")
	var paint: PaintOption = picked[0]
	var rim: RimStyle = picked[1]
	var r := _run(true)
	eq(r.state, Game.MENU)
	eq(r.car.car.id, &"night_viper", "the attract car is the selected car")
	check(r.car.look.paint.is_equal_approx(paint.color), "in its paint")
	eq(r.car.look.rim, rim, "on its rims")
	check(r.attract.is_active())
	_tap(r.title.title.play_button)
	eq(r.state, Game.COUNTDOWN)
	eq(r.car.car.id, &"night_viper", "PLAY drives it")
	eq(r.car.look.rim, rim)
	_crash_to_results(r)
	eq(r.last_results.get(&"car", ""), "night_viper", "the leaderboard payload's car")
	eq(r.car_index, Run.CAR_PATHS.find(cat.slot(&"night_viper").car_path), "the verifier's index")
	_tap(r.screens.results_screen.retry_button)
	eq(r.car.car.id, &"night_viper", "RETRY keeps it")


func test_the_garage_on_the_title_swaps_the_attract_car() -> void:
	var p := Garage.profile()
	p.stats[MetaProfile.XP] = Progression.xp_to_reach(t.progression.max_level, t.progression)
	p.stats[MetaProfile.BEST_LEG] = t.progression.unlock_leg_milestone
	p.refresh_unlocks()
	var r := _run(true)
	eq(r.car.car.id, cat.slots[0].id)
	_tap(r.title.title.garage_button)
	r.title.finish_animations()
	var g := r.title.garage
	_tap(g.item(&"brute_v8"))
	_tap(g.done_button)
	eq(r.state, Game.MENU, "still the title")
	eq(r.car.car.id, &"brute_v8", "DONE: the attract drive takes the new car")
	check(r.attract.is_active(), "and keeps driving it")
	eq(r.car.controller, r.attract.bot)
	_ticks(r, TICKS_PER_FRAME * 10)
	gt(r.car.state.v, 0.0)
	var car_before := r.car
	_tap(r.title.title.garage_button)
	r.title.finish_animations()
	_tap(r.title.garage.done_button)
	eq(r.car, car_before, "no change, no rebuild")


func test_results_garage_opens_the_garage() -> void:
	var r := _run(true)
	_tap(r.title.title.play_button)
	_crash_to_results(r)
	check(not r.screens.results_screen.garage_button.disabled)
	_tap(r.screens.results_screen.garage_button)
	eq(r.state, Game.MENU, "back on the title")
	check(r.title.garage != null and r.title.garage.visible, "with the garage open")
	check(not r.title.title.visible)
	eq(r.screens.visible_item_count(), 0, "the results closed")


func test_direct_boots_keep_car_index() -> void:
	_select(&"night_viper")
	var r := _run(false, 2)
	eq(r.car.car.id, (load(Run.CAR_PATHS[2]) as CarDef).id, "tests and tools keep car_index")
	check(CarLook.same(r.car.look, null, r.car.car), "in the factory look")


func test_car_boot_param_resolves_an_index_or_an_id() -> void:
	eq(Run.car_index_of("1"), 1)
	eq(Run.car_index_of(str(Run.CAR_PATHS.size() + 2)), 2, "wraps")
	for i in Run.CAR_PATHS.size():
		var id := String((load(Run.CAR_PATHS[i]) as CarDef).id)
		eq(Run.car_index_of(id), i, id)
	eq(Run.car_index_of("no_such_car"), 0)


func test_the_look_never_changes_the_run() -> void:
	var fancy := CarLook.make(cat.paints[3].color, cat.rims[cat.rims.size() - 1])
	var a := await _trace(null)
	var b := await _trace(fancy)
	eq(a, b, "identical traces with any paint and rims")


func _trace(look: CarLook) -> PackedInt64Array:
	var r := _run(false, 1, look)
	if look != null:
		eq(r.car.look, look, "the look is on")
	var bot := SandboxBot.new(r.road, r.sim.state, r.car.params, BOT_SEED)
	bot.mode = SandboxBot.Mode.WEAVE
	bot.v_target = BOT_SPEED_MPS
	bot.length_m = r.car.car.length_m
	bot.width_m = r.car.car.width_m
	r.drive_controller = bot
	r.go()
	var out := PackedInt64Array()
	var per := roundi(float(t.vehicle.physics_tick_hz))
	for s in roundi(TRACE_S):
		_ticks(r, per)
		out.append(r.trace_hash())
	_nodes.erase(r)
	r.queue_free()
	await tree.process_frame
	return out
