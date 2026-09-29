extends WBTest
## The biome plan in the real run (WP6.4a): each checkpoint hands over to the next
## leg's biome (Events.biome_changed, the leg_started biome the HUD toast names), the
## run's road follows the plan (desert lanes, canyon tunnels with 2 lanes), and the
## same seed gives the same journey. Spec: World → Biomes ("Each leg is one biome"),
## Legs and checkpoints (the leg summary toast), Architecture rule 2. docs/BIOMES.md.

const RUN_SCENE := preload("res://src/run/run.tscn")
const SEED := 20260929
const FRAME_S := 1.0 / 60.0
const TICKS_PER_FRAME := 2
const APPROACH_M := 15.0
const APPROACH_KMH := 200.0

var t: Tuning
var _runs: Array[Run] = []
var _changed: Array[StringName] = []
var _started: Array[StringName] = []


func _on_changed(b: StringName) -> void:
	_changed.append(b)


func _on_leg(_leg: int, b: StringName, _o: StringName) -> void:
	_started.append(b)


func before_each() -> void:
	t = Tuning.load_default()
	_changed.clear()
	_started.clear()
	Events.biome_changed.connect(_on_changed)
	Events.leg_started.connect(_on_leg)


func after_each() -> void:
	Events.biome_changed.disconnect(_on_changed)
	Events.leg_started.disconnect(_on_leg)
	for r in _runs:
		r.queue_free()
	_runs.clear()
	await tree.process_frame


func _make(run_seed: int = SEED) -> Run:
	var r := RUN_SCENE.instantiate() as Run
	r.run_seed = run_seed
	r.manual_ticks = true
	r.crash_cinematic = false
	r.record_best = false
	tree.root.add_child(r)
	_runs.append(r)
	r.infinite_lives = true
	return r


func _run_ticks(r: Run, n: int) -> void:
	for i in n:
		r.tick()
		if i % TICKS_PER_FRAME == TICKS_PER_FRAME - 1:
			r.frame(FRAME_S)


func _cross(r: Run) -> void:
	var done := r.legs.legs_completed
	var cp := r.legs.distance_to_checkpoint(r.car.state.s)
	r.dev_teleport(r.car.state.s + cp - APPROACH_M, Units.kmh_to_mps(APPROACH_KMH))
	var ticks := 0
	while r.legs.legs_completed == done and ticks < 360:
		_run_ticks(r, TICKS_PER_FRAME)
		ticks += TICKS_PER_FRAME
	eq(r.legs.legs_completed, done + 1, "crossed checkpoint %d" % (done + 1))
	_run_ticks(r, TICKS_PER_FRAME * 4)


func test_checkpoints_hand_over_to_the_next_biome() -> void:
	var r := _make()
	r.go()
	_run_ticks(r, TICKS_PER_FRAME)
	for i in 4:
		_cross(r)
	var want: Array[StringName] = []
	for leg in range(1, 6):
		want.append(r.biome_director.plan.biome_for_leg(leg).id)
	eq(_started.slice(_started.size() - 5), want, "leg_started names each leg's biome")
	eq(want.slice(0, 5), [&"farmland", &"desert", &"desert", &"canyon", &"canyon"] as Array[StringName])
	check(_changed.has(&"desert") and _changed.has(&"canyon"), "biome_changed at the handovers: %s" % [_changed])
	var i_desert := _changed.rfind(&"desert")
	var i_canyon := _changed.rfind(&"canyon")
	lt(i_desert, i_canyon, "desert before canyon")
	eq(Hud.biome_name(&"desert"), "DESERT MESAS", "the toast names the desert")
	eq(Hud.biome_name(&"canyon"), "CANYON PASS")


func test_run_road_follows_the_plan() -> void:
	var r := _make()
	var leg := t.legs.leg_length_m()
	r.road.hold_at_forks = false   # WP6.5: the whole planned road, past unresolved forks
	r.road.ensure_generated_to(leg * 5.0)
	var all: Array[RoadFeature] = []
	r.road.features_in(0.0, leg * 5.0, all)
	var tunnels := 0
	for f in all:
		if f.kind == RoadFeature.Kind.TUNNEL:
			tunnels += 1
			var in_leg := int(floor(f.s_start / leg)) + 1
			eq(r.biome_director.biome_at(f.s_start).id, &"canyon", "tunnel in leg %d is canyon" % in_leg)
			eq(r.road.lane_count(0.5 * (f.s_start + f.s_end)), t.road.tunnel_lanes, "2 lanes in the tunnel")
	gt(tunnels, 0, "canyon tunnels on the run's road")


## Same seed, same journey: road trace (geometry, lanes, features) and biome sequence.
func test_same_seed_same_journey() -> void:
	var hashes: Array[int] = []
	for k in 2:
		var r := _make()
		var leg := t.legs.leg_length_m()
		r.road.ensure_generated_to(leg * 6.0)
		var h := TraceHash.SEED
		var smp := RoadSample.new()
		var s := 0.0
		while s < leg * 6.0:
			r.road.sample_into(s, smp)
			h = TraceHash.mix_float(h, smp.pos_x)
			h = TraceHash.mix_float(h, smp.pos_z)
			h = TraceHash.mix_int(h, r.road.lane_count(s))
			h = TraceHash.mix_int(h, Rng.fnv1a32(String(r.biome_director.biome_at(s).id)))
			s += 25.0
		hashes.append(h)
	eq(hashes[0], hashes[1])
