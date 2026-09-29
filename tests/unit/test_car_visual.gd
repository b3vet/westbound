extends WBTest
## CarVisual (WP2.1): body roll/pitch springs, wheels, steer, brake lights; visual only.
## Spec: Car physics and feel → Visual body motion.

const DT := 1.0 / 120.0

var _tuning: Tuning
var _vt: VehicleTuning
var _nodes: Array[Node] = []


func before_all() -> void:
	_tuning = Tuning.load_default()
	_vt = _tuning.vehicle


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()


func _car() -> CarDef:
	return load("res://data/cars/falcon_gt.tres") as CarDef


## A visual bound to a stub model (optionally with an Interior/SteeringWheel).
func _visual(with_interior: bool = false) -> CarVisual:
	var root := CarModel.build_stub_root(_car())
	if with_interior:
		var interior := Node3D.new()
		interior.name = "Interior"
		var sw := Node3D.new()
		sw.name = "SteeringWheel"
		sw.position = Vector3(-0.35, 0.9, -0.3)
		sw.basis = Basis(Vector3.RIGHT, -0.4)   # tilted column
		interior.add_child(sw)
		root.add_child(interior)
	var model := CarModel.from_root(root, _car())
	var v := CarVisual.new()
	v.add_child(model.root)
	_nodes.append(v)
	v.bind(model, _vt)
	return v


func test_step_response_is_a_2_5_hz_spring_with_damping_0_6() -> void:
	var v := _visual()
	var st := VehicleState.new()
	var inp := VehicleInput.new()
	# A small step (well inside the clamp) so the spring is linear.
	st.accel_lat = _vt.body_roll_full_accel_mps2 * 0.25
	var target := deg_to_rad(_vt.body_roll_max_deg) * 0.25
	var trace := PackedFloat64Array()
	for i in 360:
		v.tick(DT, st, inp)
		trace.append(v.roll)
	# First peak (sub-tick by a parabola through the top three samples).
	var k := 1
	while k < trace.size() - 1 and not (trace[k] >= trace[k - 1] and trace[k] >= trace[k + 1]):
		k += 1
	var a := trace[k - 1]
	var b := trace[k]
	var c := trace[k + 1]
	var off := 0.5 * (a - c) / (a - 2.0 * b + c)
	var peak := b - 0.25 * (a - c) * off
	var t_peak := (float(k) + off + 1.0) * DT   # trace[i] is the state after i + 1 ticks
	var overshoot := (peak - target) / target
	var zeta := -log(overshoot) / sqrt(PI * PI + log(overshoot) * log(overshoot))
	var wd := PI / t_peak
	var f := wd / sqrt(1.0 - zeta * zeta) / TAU
	within_pct(f, _vt.body_spring_hz, 0.03, "natural frequency (Hz)")
	near(zeta, _vt.body_damping_ratio, 0.02, "damping ratio")
	near(trace[trace.size() - 1], target, target * 0.001, "settles on the target")
	gt(v.roll, 0.0, "leans")


func test_roll_and_pitch_never_exceed_their_maxima() -> void:
	var v := _visual()
	var st := VehicleState.new()
	var inp := VehicleInput.new()
	var rng := Rng.new(7)
	var roll_max := deg_to_rad(_vt.body_roll_max_deg)
	var pitch_max := deg_to_rad(_vt.body_pitch_max_deg)
	var worst_roll := 0.0
	var worst_pitch := 0.0
	for i in 2400:
		if i % 30 == 0:   # violent steps, the spec's peak lateral accel is ~37 m/s^2
			st.accel_lat = rng.float_range(-40.0, 40.0)
			st.accel_long = rng.float_range(-14.0, 10.0)
		v.tick(DT, st, inp)
		worst_roll = maxf(worst_roll, absf(v.roll))
		worst_pitch = maxf(worst_pitch, absf(v.pitch))
		var up := v.model.body.transform.basis.y
		worst_roll = maxf(worst_roll, absf(asin(clampf(up.x, -1.0, 1.0))))
	le(worst_roll, roll_max + 1e-9, "roll <= %s deg" % _vt.body_roll_max_deg)
	le(worst_pitch, pitch_max + 1e-9, "pitch <= %s deg" % _vt.body_pitch_max_deg)
	gt(worst_roll, roll_max * 0.99, "reaches the full roll")


func test_signs_lean_out_and_squat() -> void:
	var v := _visual()
	var st := VehicleState.new()
	var inp := VehicleInput.new()
	st.accel_lat = 8.0   # turning right
	st.accel_long = 5.0  # accelerating
	for i in 120:
		v.tick(DT, st, inp)
	var b := v.model.body.transform.basis
	lt(b.y.x, 0.0, "turning right leans the body to the left (outward)")
	gt((-b.z).y, 0.0, "accelerating lifts the nose")
	st.accel_long = -9.0
	for i in 120:
		v.tick(DT, st, inp)
	lt((-v.model.body.transform.basis.z).y, 0.0, "braking dives the nose")
	# Wheels stay planted: the pivots are not sprung.
	near(v.model.wheels[0].position.y, v.model.wheel_radius_m, 1e-6, "front wheel hub on its rest height")
	near(v.model.wheels[3].position.y, v.model.wheel_radius_m, 1e-6, "rear wheel hub on its rest height")


func test_wheels_spin_at_v_over_r_and_front_wheels_steer() -> void:
	var v := _visual()
	var st := VehicleState.new()
	var inp := VehicleInput.new()
	var r := v.model.wheel_radius_m
	gt(r, 0.2, "wheel radius from the model")
	st.v = 30.0
	near(v.wheel_spin_rate(st.v), 30.0 / r, 1e-9, "spin rate = v / r")
	var a0 := v.wheel_angle
	v.tick(DT, st, inp)
	near(v.wheel_angle, fposmod(a0 + 30.0 / r * DT, TAU), 1e-9, "one tick of spin")
	var turns := 0.0
	for i in 119:
		v.tick(DT, st, inp)
	turns = fposmod(a0 + 30.0 / r * DT * 120.0, TAU)
	near(v.wheel_angle, turns, 1e-6, "one second of spin")
	# The rim turns about the axle; rolling forward moves the top of the wheel forward.
	var rim := v.model.rims[1]
	var top := rim.transform.basis * Vector3.UP
	var expect := Basis(Vector3.RIGHT, -v.wheel_angle) * Vector3.UP
	near(top.distance_to(expect), 0.0, 1e-5, "rim rotation matches the spin")
	st.v = 1.0
	v.wheel_angle = 0.0
	v.tick(DT, st, inp)
	lt((v.model.rims[1].transform.basis * Vector3.UP).z, 0.0, "forward roll: top moves toward -Z")
	# Steer.
	st.steer_angle = 0.2
	v.tick(DT, st, inp)
	for i in 2:
		var fwd := -v.model.wheels[i].transform.basis.z
		near(atan2(fwd.x, -fwd.z), 0.2, 1e-6, "front wheel shows the steer angle (right = +X)")
	for i: int in [2, 3]:
		var fwd := -v.model.wheels[i].transform.basis.z
		near(fwd.x, 0.0, 1e-9, "rear wheels do not steer")


func test_brake_lights_follow_brake_input() -> void:
	var v := _visual()
	var st := VehicleState.new()
	var inp := VehicleInput.new()
	var brakes := v.model.brakes_mesh
	check(brakes != null, "brake_L + brake_R merged into one draw")
	v.tick(DT, st, inp)
	check(not brakes.visible, "off without braking")
	inp.brake = 1.0
	v.tick(DT, st, inp)
	check(brakes.visible, "on while braking")
	check(v.brake_lights_on, "flag")
	inp.brake = Units.pct_to_frac(_vt.brake_light_min_input_pct) * 0.5
	v.tick(DT, st, inp)
	check(not brakes.visible, "off below the threshold")
	check(v.model.lamps_mesh != null and v.model.lamps_mesh.visible,
		"head and tail lamps always drawn (night ramp in the shader)")
	for key: StringName in CarModel.BRAKE_NAMES + CarModel.LAMP_NAMES:
		check(not (v.model.light[key] as Node3D).visible, "%s folded into a merged draw" % key)


func test_tire_smoke_flag() -> void:
	var v := _visual()
	var st := VehicleState.new()
	var inp := VehicleInput.new()
	inp.brake = 1.0
	st.v = Units.kmh_to_mps(_vt.tire_smoke_min_speed_kmh + 20.0)
	st.accel_long = -(_vt.tire_smoke_min_decel_mps2 + 2.0)
	v.tick(DT, st, inp)
	check(v.tire_smoke, "hard braking at speed smokes")
	st.v = Units.kmh_to_mps(_vt.tire_smoke_min_speed_kmh - 20.0)
	v.tick(DT, st, inp)
	check(not v.tire_smoke, "not below the speed")


func test_steering_wheel_turns_with_steer() -> void:
	var v := _visual(true)
	check(v.model.steering_wheel != null, "interior resolved")
	var rest := v.model.steering_wheel.transform
	var st := VehicleState.new()
	st.steer_angle = 0.1
	v.tick(DT, st, VehicleInput.new())
	var rel := rest.basis.inverse() * v.model.steering_wheel.transform.basis
	var ang := atan2(rel.x.y, rel.x.x)   # rotation about the column (local Z)
	near(ang, -0.1 * _vt.steering_wheel_ratio_factor, 1e-5, "wheel angle = -steer x ratio (clockwise seen by the driver)")
	near(v.model.steering_wheel.position.distance_to(rest.origin), 0.0, 1e-6, "turns in place")


func test_visual_never_mutates_state_or_input() -> void:
	var v := _visual()
	var st := VehicleState.new()
	var inp := VehicleInput.new()
	var rng := Rng.new(3)
	for i in 600:
		st.v = rng.float_range(0.0, 80.0)
		st.accel_lat = rng.float_range(-30.0, 30.0)
		st.accel_long = rng.float_range(-12.0, 9.0)
		st.steer_angle = rng.float_range(-0.5, 0.5)
		st.yaw = rng.float_range(-0.2, 0.2)
		inp.brake = rng.float_range(0.0, 1.0)
		inp.steer = rng.float_range(-1.0, 1.0)
		var hs := st.trace_hash()
		var hi := inp.hash_into(TraceHash.SEED)
		v.tick(DT, st, inp)
		if not eq(st.trace_hash(), hs, "state untouched") or not eq(inp.hash_into(TraceHash.SEED), hi, "input untouched"):
			return


func test_damage_hook() -> void:
	var v := _visual()
	v.set_damage_level(1)
	eq(v.damage_level, 1, "first-hit look requested (Phase 4 draws it)")
	check(v.model.marker(&"smoke_hood") != null, "smoke marker exists for Phase 4")


func test_tick_creates_no_objects() -> void:
	var v := _visual(true)
	var st := VehicleState.new()
	var inp := VehicleInput.new()
	st.v = 40.0
	for i in 10:
		v.tick(DT, st, inp)
	var before := Performance.get_monitor(Performance.OBJECT_COUNT)
	for i in 600:
		st.accel_lat = 10.0 if i % 60 < 30 else -10.0
		inp.brake = 1.0 if i % 50 < 10 else 0.0
		v.tick(DT, st, inp)
	le(Performance.get_monitor(Performance.OBJECT_COUNT) - before, 0.0, "no objects per tick")


# ---------------------------------------------------------------- Draw-call merge (WP4.6)

## The player car and its merged draws, for a real placeholder model.
func _real_visual(car: CarDef) -> CarVisual:
	var model := CarModel.load_model(car.model_scene_path, car)
	var v := CarVisual.new()
	v.add_child(model.root)
	_nodes.append(v)
	model.apply_paint(car.default_paint)
	v.bind(model, _vt)
	return v


func test_every_car_draws_within_the_merged_target() -> void:
	for f in DirAccess.get_files_at("res://data/cars"):
		if not f.ends_with(".tres"):
			continue
		var car := load("res://data/cars".path_join(f)) as CarDef
		var loose := CarModel.load_model(car.model_scene_path, car)
		var before := loose.draw_surface_count()
		loose.root.free()
		var v := _real_visual(car)
		var after := v.model.draw_surface_count()
		print("      %s: %d draw surfaces -> %d" % [car.id, before, after])
		le(after, CarModel.MERGED_DRAW_SURFACES_MAX, "%s merged draws" % car.id)
		eq(v.model.wheel_draws.size(), 1, "%s: the four wheels share one MultiMesh" % car.id)
		eq(v.model.wheel_draws[0].mm.instance_count, 4, "%s: four wheel instances" % car.id)
		var st := VehicleState.new()
		var inp := VehicleInput.new()
		inp.brake = 1.0
		v.tick(DT, st, inp)
		eq(v.model.draw_surface_count(), after + 1, "%s: braking adds one draw" % car.id)
		eq(v.model.missing_nodes().size(), 0, "%s: convention nodes kept" % car.id)


func test_merged_geometry_matches_the_parts() -> void:
	var v := _real_visual(_car())
	var m := v.model
	# Lamps: the same triangles and material as the four lamp quads.
	var tris := 0
	for key: StringName in CarModel.LAMP_NAMES:
		tris += CarModel.triangle_count((m.light[key] as MeshInstance3D).mesh)
	eq(CarModel.triangle_count(m.lamps_mesh.mesh), tris, "lamp triangles")
	eq(m.lamps_mesh.mesh.get_surface_count(), 1, "one lamp surface")
	eq(m.lamps_mesh.get_active_material(0), CarModel.slot_material(CarModel.Slot.LAMP), "lamp material")
	# A merged lamp vertex lands where the part's vertex was (Lights space).
	var head := m.light[&"headlight_L"] as MeshInstance3D
	var p := head.transform * (head.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array)[0]
	var found := false
	for q: Vector3 in m.lamps_mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array:
		found = found or q.distance_to(p) < 1e-5
	check(found, "headlight vertex kept in place")
	# Wheels: tire + rim triangles in one trim surface.
	var wd := m.wheel_draws[0]
	var wheel_tris := CarModel.triangle_count((m.tires[0] as MeshInstance3D).mesh) \
		+ CarModel.triangle_count((m.rims[0] as MeshInstance3D).mesh)
	eq(CarModel.triangle_count(wd.mm.mesh), wheel_tris, "wheel triangles")
	eq(wd.mm.mesh.get_surface_count(), 1, "one wheel surface")
	check(wd.mm.use_colors, "white instance colors (Compatibility quirk)")


func test_wheel_instances_follow_the_nodes() -> void:
	# Each instance must sit exactly where the (hidden) Tire node would draw, through
	# spin and steer, so the merge changes no pixel.
	var v := _real_visual(_car())
	var m := v.model
	var st := VehicleState.new()
	var inp := VehicleInput.new()
	st.v = 37.0
	for step in 30:
		st.steer_angle = 0.3 * sin(float(step) * 0.2)
		v.tick(DT, st, inp)
		var wd := m.wheel_draws[0]
		for k in wd.wheel.size():
			var tire := m.tires[wd.wheel[k]]
			var want := m.wheels[wd.wheel[k]].transform * tire.transform
			var got := wd.written[k]
			if not near(got.origin.distance_to(want.origin), 0.0, 1e-5, "instance %d origin" % k):
				return
			for axis in 3:
				if not near((got.basis[axis] - want.basis[axis]).length(), 0.0, 1e-5, "instance %d basis" % k):
					return


func test_merge_is_idempotent_and_keeps_paint() -> void:
	var v := _real_visual(_car())
	var m := v.model
	var n := m.draw_surface_count()
	m.merge_draw_surfaces()
	v.bind(m, _vt)
	eq(m.draw_surface_count(), n, "a second merge changes nothing")
	var paint := m.body.get_active_material(0) as ShaderMaterial
	var c := _car().default_paint
	eq(paint.get_shader_parameter(&"paint_color"), Vector3(c.r, c.g, c.b), "paint kept on the body")


func test_split_light_takes_one_lamp_back_out() -> void:
	var v := _real_visual(_car())
	var m := v.model
	var n := m.draw_surface_count()
	var tris := CarModel.triangle_count(m.lamps_mesh.mesh)
	var head := m.split_light(&"headlight_L")
	check(head != null and head.visible, "the lamp is its own visible node again")
	eq(CarModel.triangle_count(m.lamps_mesh.mesh), tris - CarModel.triangle_count(head.mesh),
		"and no longer in the merged lamps (no double draw)")
	eq(m.draw_surface_count(), n + 1, "one more draw while split")
	eq(m.split_light(&"headlight_L"), head, "splitting twice is harmless")
	check(m.split_light(&"brake_L") == null, "only merged head/tail lamps split")
