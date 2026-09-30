extends WBTest
## The set pieces' props, their hits and the tunnel light (WP6.3). Spec: Traffic →
## set-piece table (signs; cones and a barrier; a flashing arrow board; the on-ramp;
## booth and express lanes); World → Night lighting ("reflectors and signs:
## retro-reflective material"); Lives → what counts as a hit ("roadside objects", the
## first touch); Performance budget (draw calls); "light change at entry and exit".
## docs/SET_PIECES.md.

const SEED := 630501
const SKY_SCENE := "res://src/sun/sky.tscn"
const DT := 1.0 / 120.0

var tuning: Tuning
var _nodes: Array[Node] = []


func before_all() -> void:
	tuning = Tuning.load_default()


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()


func _view(r: SetPieceRig) -> SetPieceView:
	var o := FloatingOrigin.new()
	tree.root.add_child(o)
	o.setup(tuning.road.floating_origin_shift_km)
	_nodes.append(o)
	var v := SetPieceView.new()
	tree.root.add_child(v)
	_nodes.append(v)
	v.setup(r.ctx, r.road, o)
	v.bind(r.dir.set_pieces)
	return v


## Faces of the slot's mesh with emissive class `cls` (UV2.x).
static func _faces(sl: SetPieceView.Slot, cls: float) -> int:
	if sl.mesh.get_surface_count() == 0:
		return 0
	var uv2: PackedVector2Array = sl.mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]
	var n := 0
	for k in range(0, uv2.size(), 3):
		if uv2[k].x == cls:
			n += 1
	return n


func _live_slot(v: SetPieceView) -> SetPieceView.Slot:
	for sl in v.slots:
		if sl.serial >= 0:
			return sl
	return null


# ---------------------------------------------------------------- Props and draw calls

func test_road_works_props_are_drawn_retro_reflective_in_three_draw_calls() -> void:
	var r := SetPieceRig.new(SEED, 3, null, null, 200.0, 1)
	var v := _view(r)
	v.update_view(r.bot.state.s)
	eq(v.draw_calls(), 0, "nothing drawn without a piece")
	var inst := r.force(&"road_works")
	if not check(inst != null, "live"):
		return
	var w := inst.controller as RoadWorksPiece
	v.update_view(r.bot.state.s)
	var sl := _live_slot(v)
	if not check(sl != null, "the piece got a slot"):
		return
	eq(sl.serial, inst.serial)
	gt(sl.mesh.get_surface_count(), 0, "its props were built")
	# Seen from the 400 m sign on (the player comes up to it): signs, barrier, board, cones.
	v.update_view(inst.warn_s - 420.0)
	check(sl.node.visible, "visible from before its sign")
	eq(v.cones.multimesh.visible_instance_count, mini(w.cone_s.size(), v.look.max_cones), "every cone")
	check(v.cones.visible, "the cones")
	le(v.draw_calls(), 3, "at most three draw calls")
	eq(v.draw_calls(), 2, "the piece's mesh and its cones")
	gt(_faces(sl, SetPieceMeshBuilder.EMISSIVE_REFLECTOR), 10, "retro-reflective sign face, barrier, board frame")
	gt(_faces(sl, SetPieceMeshBuilder.EMISSIVE_FLASH), 4, "the arrow's lamps")
	check(sl.flashes, "the arrow board flashes")
	# The cones' collars are retro-reflective too.
	var cm := v.cones.multimesh.mesh
	var uv2: PackedVector2Array = cm.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]
	var retro := 0
	for k in uv2.size():
		if uv2[k].x == SetPieceMeshBuilder.EMISSIVE_REFLECTOR:
			retro += 1
	gt(retro, 0, "cone collars reflect")
	# The flash toggles with the view's clock.
	var gains := {}
	for k in 40:
		v.set(&"_clock", float(k) * 0.05)
		v.update_view(inst.zone_s0 - 50.0)
		gains[float(sl.material.get_shader_parameter(&"flash_gain"))] = true
	eq(gains.size(), 2, "on and off")
	# Past it, and when it ends, nothing is drawn.
	check(r.run_until_ended(inst, 90.0), "ended")   # the bot drives ~100 km/h behind the zone's traffic: ~65 s
	v.update_view(r.bot.state.s)
	eq(v.draw_calls(), 0, "nothing drawn once it ended")


func test_merge_zone_and_toll_props() -> void:
	var r := SetPieceRig.new(SEED + 1, 3, null, null, 200.0, 0)
	var v := _view(r)
	var inst := r.force(&"merge_zone")
	if not check(inst != null, "merge zone live"):
		return
	v.update_view(r.bot.state.s)
	var sl := _live_slot(v)
	if check(sl != null, "built"):
		v.update_view(inst.zone_s0 - 300.0)
		eq(v.draw_calls(), 1, "merge: one draw call: signs, ramp, gore, rail, attenuator (s0 %.0f s1 %.0f vis %s)" % [
			sl.s0, sl.s1, sl.node.visible])
		gt(_faces(sl, SetPieceMeshBuilder.EMISSIVE_REFLECTOR), 4, "retro-reflective signs and attenuator")
		le(sl.s0, inst.zone_s0 - inst.def.ramp_length_m, "the ramp comes in from before the nose")
		le(sl.s0, inst.warn_s - 500.0, "and the 500 m sign")
	# Toll gantry: the legends in the lanes.
	var cp := tuning.legs.leg_length_m()
	var r2 := SetPieceRig.new(SEED, 3, null, null, 200.0, 1, cp - 2000.0)
	r2.all_tolls()
	var v2 := _view(r2)
	var toll := r2.force(&"toll_gantry")
	if check(toll != null, "toll live"):
		v2.update_view(r2.bot.state.s)
		var sl2 := _live_slot(v2)
		if check(sl2 != null, "built"):
			var n := int(sl2.mesh.surface_get_array_len(0) / 6.0)
			eq(n, toll.lanes, "one painted legend per lane")
			v2.update_view((toll.controller as TollGantryPiece).checkpoint_s - 200.0)
			eq(v2.draw_calls(), 1, "toll: one draw call (s0 %.0f s1 %.0f vis %s serial %d)" % [sl2.s0, sl2.s1, sl2.node.visible,
				sl2.serial])


# ---------------------------------------------------------------- Hits on the props

func test_the_player_hits_cones_the_barrier_and_the_board() -> void:
	var r := SetPieceRig.new(SEED, 3, null, null, 200.0, 1)
	var inst := r.force(&"road_works")
	if not check(inst != null, "live"):
		return
	var w := inst.controller as RoadWorksPiece
	var hd := HitDetection.new(tuning.lives, 0)
	hd.set_player_body(4.5, 1.9)
	hd.set_prop_query(r.works)
	var c := HitDetection.Contact.new()
	var p := VehicleState.new()
	var mid := int(w.cone_s.size() / 2.0)
	var d := inst.def
	# [near end s, d] of each prop.
	var cases := {
		"a cone": [w.cone_s[mid] - d.cone_size_m * 0.5, w.cone_d[mid]],
		"the barrier": [w.barrier_s0, w.barrier_d],
		"the arrow board": [w.arrow_s - d.arrow_board_length_m * 0.5, w.arrow_d],
	}
	var hl := 4.5 * 0.5 - tuning.lives.collision_inset_m
	for what: String in cases:
		var at: Array = cases[what]
		# 350 km/h into it: the nose crosses its near end within one tick.
		var v := Units.kmh_to_mps(350.0)
		p.s = float(at[0]) - hl - v * DT * 0.5
		p.d = float(at[1])
		p.yaw = 0.0
		hd.reset(p, null)
		p.s += v * DT
		check(hd.step(DT, p, null, null, c), "%s is hit" % what)
		eq(c.source, HitDetection.HIT_PROP, "%s: a prop hit" % what)
		eq(c.end, 1, "%s: at the nose" % what)
	# Driving past in the open lane touches nothing.
	var open_lane := w.closed_lo - 1 if w.side > 0 else w.closed_hi + 1
	p.d = r.road.lane_center_d(open_lane, inst.zone_s0)
	p.s = inst.zone_s0 - 10.0
	hd.reset(p, null)
	var hits := 0
	while p.s < inst.zone_s1 + 10.0:
		p.s += Units.kmh_to_mps(200.0) * DT
		if hd.step(DT, p, null, null, c):
			hits += 1
	eq(hits, 0, "the open lane is clear of props")


# ---------------------------------------------------------------- Tunnel light in the sky

func test_the_sky_darkens_and_lights_the_lamps_inside_a_tunnel() -> void:
	var pushed := {}
	var sky := (load(SKY_SCENE) as PackedScene).instantiate() as SkyRig
	sky.push_sink = func(n: StringName, value: Variant) -> void: pushed[n] = value
	sky.sky_t = tuning.sun.sky_t_afternoon
	sky.set_process(false)
	tree.root.add_child(sky)
	_nodes.append(sky)
	sky.push_now()
	var amb0: Color = pushed[&"wb_ambient"]
	var sun0: float = pushed[&"wb_sun_light_energy"]
	var lamp0: float = pushed[&"wb_emissive_streetlamp"]
	eq(lamp0, 0.0, "no lamps by day")
	sky.set_tunnel_light(1.0, 0.5, 1.0)
	sky.push_now()
	var amb1: Color = pushed[&"wb_ambient"]
	near(amb1.r, amb0.r * 0.5, 1e-5, "darker ambient inside")
	near(float(pushed[&"wb_sun_light_energy"]), sun0 * 0.5, 1e-5, "and sun light")
	near(float(pushed[&"wb_emissive_streetlamp"]), 1.0, 1e-5, "the lamp strips on")
	sky.set_tunnel_light(0.0, 0.5, 1.0)
	sky.push_now()
	eq(pushed[&"wb_ambient"], amb0, "back outside")
	eq(float(pushed[&"wb_emissive_streetlamp"]), lamp0)
