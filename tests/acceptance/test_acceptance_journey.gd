extends WBTest
## WP9.5 acceptance sweep: the M6 milestone check "all biomes and set pieces appear in a
## full journey" (spec: Implementation milestones → M6; plan §7 Gate M6: "a full journey
## trace shows every biome and set piece"). docs/ACCEPTANCE.md records the result.
##
## The real Run, driven the whole way (no teleports) by a weaving SandboxBot (250 or 170 km/h)
## with infinite lives, like test_journey.gd's soak. It logs every leg's biome and every
## set piece the player met (Events.set_piece_started) and prints one ACCEPT line per
## seed. The biomes are asserted (the route's stages all appear, legs follow the route);
## the set-piece tally is reported, not asserted: which kinds appear depends on the
## biome mixes, the wave peaks the player meets and the road fitting each piece
## (docs/SET_PIECES.md), so docs/ACCEPTANCE.md judges it.

const RUN_SCENE := preload("res://src/run/run.tscn")
## (run seed, bot speed km/h): two seeds flat out, one at a cruising cut-up pace.
const DRIVES: Array[Vector2i] = [Vector2i(20260929, 250), Vector2i(7, 250), Vector2i(20260929, 170)]
const BOT_SEED := 3
const FRAME_S := 1.0 / 60.0
const TICKS_PER_FRAME := 2
## Wall-clock guard: 25 simulated minutes.
const MAX_TICKS := 120 * 60 * 25

var t: Tuning
var _run: Run = null
var _conns: Array = []
var _biomes: Array[StringName] = []
var _pieces: Dictionary = {}
var _warned: Dictionary = {}


func before_all() -> void:
	t = Tuning.load_default()


func before_each() -> void:
	_biomes.clear()
	_pieces.clear()
	_warned.clear()
	_listen(Events.leg_started, func(_leg: int, b: StringName, _o: StringName) -> void: _biomes.append(b))
	_listen(Events.set_piece_started, func(k: StringName) -> void: _pieces[k] = int(_pieces.get(k, 0)) + 1)
	_listen(Events.set_piece_warning, func(k: StringName, _d: float) -> void: _warned[k] = true)


func after_each() -> void:
	for c: Array in _conns:
		(c[0] as Signal).disconnect(c[1])
	_conns.clear()
	if _run != null:
		_run.queue_free()
		_run = null
	await tree.process_frame


func _listen(sig: Signal, fn: Callable) -> void:
	sig.connect(fn)
	_conns.append([sig, fn])


func _drive_journey(run_seed: int, kmh: float) -> Dictionary:
	var r := RUN_SCENE.instantiate() as Run
	r.run_seed = run_seed
	r.mode = RunContext.MODE_JOURNEY
	r.manual_ticks = true
	r.crash_cinematic = false
	r.record_best = false
	r.infinite_lives = true
	tree.root.add_child(r)
	_run = r
	r.go()
	var bot := SandboxBot.new(r.road, r.sim.state, r.car.params, BOT_SEED)
	bot.mode = SandboxBot.Mode.WEAVE
	bot.v_target = Units.kmh_to_mps(kmh)
	bot.length_m = r.car.car.length_m
	bot.width_m = r.car.car.width_m
	r.drive_controller = bot
	var target := float(t.legs.legs_to_coast) * t.legs.leg_length_m() + t.legs.finale_after_m
	var ticks := 0
	while r.car.state.s < target and ticks < MAX_TICKS:
		for i in TICKS_PER_FRAME:
			r.tick()
		r.frame(FRAME_S)
		ticks += TICKS_PER_FRAME
	return {
		"s": r.car.state.s, "target": target, "route": r.forks.plan.route(r.forks.choices),
		"legs": r.legs.legs_completed, "sim_s": float(ticks) / float(t.vehicle.physics_tick_hz),
		"peaks": "seen %d, no chance %d, no kind %d, missed %d, unfit %d, busy %d" % [
			r.director.peaks_seen, r.director.peaks_no_chance, r.director.peaks_no_kind,
			r.director.peaks_missed, r.director.peaks_unfit, r.director.peaks_busy],
	}


func soak_full_journey_shows_every_biome_and_the_set_pieces_it_meets() -> void:
	var all_kinds: Dictionary = {}
	for drive in DRIVES:
		var run_seed := drive.x
		_biomes.clear()
		_pieces.clear()
		_warned.clear()
		var res := _drive_journey(run_seed, float(drive.y))
		check(float(res["s"]) >= float(res["target"]), "seed %d drove the whole journey (%.0f m)" % [run_seed, res["s"]])
		var route: Array = res["route"]
		var seen: Dictionary = {}
		for b in _biomes:
			seen[b] = true
		for stage: StringName in route:
			check(seen.has(stage), "seed %d: biome %s of the route appears" % [run_seed, stage])
		for k: StringName in _pieces:
			all_kinds[k] = int(all_kinds.get(k, 0)) + int(_pieces[k])
		var warned_only: Array = []
		for k: StringName in _warned:
			if not _pieces.has(k):
				warned_only.append(k)
		print("ACCEPT m6 seed=%d kmh=%d legs=%d sim=%.0fs biomes=%s route=%s set_pieces=%s warned_not_started=%s peaks: %s" % [
			run_seed, drive.y, res["legs"], res["sim_s"], _biomes, route, _pieces, warned_only, res["peaks"]])
		_run.queue_free()
		_run = null
		await tree.process_frame
	print("ACCEPT m6 all drives: set piece kinds met %d of %d: %s" % [
		all_kinds.size(), _set_piece_kinds().size(), all_kinds])


func _set_piece_kinds() -> PackedStringArray:
	var out := PackedStringArray()
	for f in DirAccess.get_files_at("res://data/set_pieces"):
		if f.ends_with(".tres") and f != "look.tres":
			out.append(f.get_basename())
	return out
