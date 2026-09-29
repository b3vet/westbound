class_name SetPieceView
extends Node3D
## Draws the set pieces' props (WP6.3). Spec: Traffic → set-piece table (merge zone
## "signs 500 m and 250 m ahead" and its on-ramp; road works "cones and a barrier",
## "signs 400 m ahead, flashing arrow board"; toll gantry booth and express lanes);
## World → Night lighting (retro-reflective signs, cones and barriers; the arrow board is
## a light source); Performance budget (draw calls). docs/SET_PIECES.md.
##
## A world-system node (docs/CONTRACTS.md §13): setup(ctx, road, origin), bind(source),
## update_view(focus_s) once per frame. It only reads SetPieceSource (the live pieces'
## controllers hold the layout, in road space); it never drives gameplay.
##
## Pools, made at setup, nothing created while driving:
##   - SLOTS MeshInstance3Ds, one per live road-anchored piece with props (merge zone,
##     road works, toll gantry): its signs, ramp and gore, barrier, arrow board or
##     legends in ONE surface (set_piece.gdshader), built once when the piece appears
##     (it is decided beyond the view, so it never pops in) and freed when it ends;
##   - one MultiMeshInstance3D for the cones of the nearest road works (look.max_cones).
## Draw calls: 1 per piece in view (+1 for its cones): at most 3 with two pieces in view
## (a live piece's zone keeps clear of another's), 0 with none (hidden nodes).
## Text (signs, legends) comes from its own small LandmarkTextAtlas.
##
## Floating origin: every node sits at its piece's 64-bit anchor minus the origin and
## moves on Events.origin_shifted. The arrow board flashes arrow_flash_hz (flash_gain,
## per frame, from its own clock: the view's, not the simulation's).

const SLOTS := 2
## Text regions per slot (two signs of two lines, two legends) and their aspect.
const LINES_PER_SLOT := 6
const LINE_ASPECT := 3.2
const MATERIAL_SHADER := preload("res://src/world/set_pieces/set_piece.gdshader")


class Slot:
	extends RefCounted
	var node: MeshInstance3D
	var mesh: ArrayMesh
	var material: ShaderMaterial
	var serial: int = -1
	var anchor_x: float = 0.0
	var anchor_y: float = 0.0
	var anchor_z: float = 0.0
	## Road range the mesh covers (visibility).
	var s0: float = 0.0
	var s1: float = 0.0
	var lines := PackedInt32Array()
	var flashes: bool = false
	var flash_hz: float = 1.0


var look: SetPieceLook
var source: SetPieceSource
var road: RoadPath
var origin: FloatingOrigin
var atlas: LandmarkTextAtlas
var slots: Array[Slot] = []
var cones: MultiMeshInstance3D
## The serial whose cones are drawn (-1 none).
var cones_serial: int = -1
var view_distance_m: float = 800.0

var _palette: WBPalette
var _builder: SetPieceMeshBuilder
var _cone_anchor := PackedFloat64Array([0.0, 0.0, 0.0])
var _clock: float = 0.0
var _connected: bool = false


func _init() -> void:
	look = SetPieceLook.load_default()
	_palette = WBPalette.load_default()
	_builder = SetPieceMeshBuilder.new(_palette)


## docs/CONTRACTS.md §13. Builds the pools and the atlas once (retries release them).
func setup(ctx: RunContext, road_path: RoadPath, floating_origin: FloatingOrigin) -> void:
	road = road_path
	origin = floating_origin
	var q := ctx.tuning.quality
	view_distance_m = q.view_distance_m[q.view_distance_m.size() - 1]
	if atlas == null:
		var lt: LandmarkTuning = ctx.tuning.landmarks.duplicate()
		lt.text_atlas_width_px = look.atlas_width_px
		lt.text_atlas_height_px = look.atlas_height_px
		atlas = LandmarkTextAtlas.new(lt)
		for k in SLOTS:
			var sl := Slot.new()
			sl.mesh = ArrayMesh.new()
			sl.material = ShaderMaterial.new()
			sl.material.shader = MATERIAL_SHADER
			sl.material.set_shader_parameter(&"text_atlas", atlas.texture)
			sl.material.set_shader_parameter(&"text_color", _palette.color(look.sign_ink_color))
			sl.node = MeshInstance3D.new()
			sl.node.name = "SetPiece%d" % k
			sl.node.mesh = sl.mesh
			sl.node.visible = false
			add_child(sl.node)
			for j in LINES_PER_SLOT:
				sl.lines.append(atlas.alloc(LINE_ASPECT))
			slots.append(sl)
		var cone_mat := ShaderMaterial.new()
		cone_mat.shader = MATERIAL_SHADER
		cone_mat.set_shader_parameter(&"text_atlas", atlas.texture)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true   # Compatibility multiplies COLOR by it (CONTRACTS §13): white
		mm.mesh = SetPieceMeshBuilder.cone_mesh(look, _palette, cone_mat)
		mm.instance_count = look.max_cones
		mm.visible_instance_count = 0
		for i in look.max_cones:
			mm.set_instance_color(i, Color.WHITE)
		cones = MultiMeshInstance3D.new()
		cones.name = "Cones"
		cones.multimesh = mm
		cones.visible = false
		add_child(cones)
	release()


## The set-piece runtime to draw (the director's).
func bind(src: SetPieceSource) -> void:
	source = src
	release()


## Frees every slot and the cones (a retry, a new director).
func release() -> void:
	for sl in slots:
		sl.serial = -1
		sl.node.visible = false
		sl.mesh.clear_surfaces()
	cones_serial = -1
	if cones != null:
		cones.visible = false
		cones.multimesh.visible_instance_count = 0


## docs/CONTRACTS.md §13: once per frame with the player's s.
func update_view(focus_s: float) -> void:
	if source == null:
		return
	_clock += get_process_delta_time()
	# Free the slots of pieces that ended, build the new ones.
	for sl in slots:
		if sl.serial >= 0 and source.instance_by_serial(sl.serial) == null:
			sl.serial = -1
			sl.node.visible = false
			sl.mesh.clear_surfaces()
	if cones_serial >= 0 and source.instance_by_serial(cones_serial) == null:
		cones_serial = -1
		cones.visible = false
	for inst in source.instances:
		if inst.stage != SetPieceSource.Stage.RUNNING or not has_props(inst) or _slot_of(inst.serial) != null:
			continue
		var sl := _free_slot()
		if sl == null:
			break
		_build(sl, inst)
	for sl in slots:
		if sl.serial < 0:
			continue
		sl.node.visible = sl.s1 >= focus_s - look.sign_width_m and sl.s0 <= focus_s + view_distance_m
		if sl.flashes:
			var on := fposmod(_clock * sl.flash_hz, 1.0) < 0.5
			sl.material.set_shader_parameter(&"flash_gain", look.arrow_on_gain if on else look.arrow_off_gain)
	if cones_serial >= 0:
		var inst := source.instance_by_serial(cones_serial)
		var works := inst.controller as RoadWorksPiece
		cones.visible = works.cone_s[works.cone_s.size() - 1] >= focus_s - look.sign_width_m \
			and works.cone_s[0] <= focus_s + view_distance_m


## True for the pieces with props here: merge zone, road works, toll gantry.
static func has_props(inst: SetPieceSource.Instance) -> bool:
	return inst.controller is MergeZonePiece or inst.controller is RoadWorksPiece or inst.controller is TollGantryPiece


## Draw calls the view costs now (tests, the dev HUD).
func draw_calls() -> int:
	var n := 0
	for sl in slots:
		if sl.node.visible and sl.mesh.get_surface_count() > 0:
			n += 1
	if cones != null and cones.visible and cones.multimesh.visible_instance_count > 0:
		n += 1
	return n


func triangles() -> int:
	var n := 0
	for sl in slots:
		if sl.node.visible and sl.mesh.get_surface_count() > 0:
			n += int(sl.mesh.surface_get_array_len(0) / 3.0)
	return n


func _slot_of(serial: int) -> Slot:
	for sl in slots:
		if sl.serial == serial:
			return sl
	return null


func _free_slot() -> Slot:
	for sl in slots:
		if sl.serial < 0:
			return sl
	return null


# ---------------------------------------------------------------- Building (once per piece)

func _build(sl: Slot, inst: SetPieceSource.Instance) -> void:
	sl.serial = inst.serial
	sl.flashes = false
	var first := minf(SetPieceSource.first_notice_s(inst.def, inst.zone_s0), inst.zone_s0)
	road.ensure_generated_to(inst.zone_s1 + look.legend_length_m)
	_builder.begin(road, first)
	sl.s0 = first
	sl.s1 = inst.zone_s1
	sl.anchor_x = _builder.anchor_x
	sl.anchor_y = _builder.anchor_y
	sl.anchor_z = _builder.anchor_z
	var line := 0
	if inst.controller is RoadWorksPiece:
		line = _signs(sl, inst, line, look.works_sign_color, "ROAD WORKS")
		_works(sl, inst)
	elif inst.controller is MergeZonePiece:
		line = _signs(sl, inst, line, look.merge_sign_color, "MERGING TRAFFIC")
		_ramp(inst)
		sl.s0 = minf(sl.s0, inst.zone_s0 - inst.def.ramp_length_m)
	elif inst.controller is TollGantryPiece:
		_legends(sl, inst, line)
	atlas.commit()
	_builder.commit(sl.mesh, sl.material)
	_place(sl.node, sl.anchor_x, sl.anchor_y, sl.anchor_z)
	sl.node.visible = true


## One warning sign per warning distance, beyond the right guardrail: the words on the
## top line, the distance under them.
func _signs(sl: Slot, inst: SetPieceSource.Instance, line: int, face: StringName, words: String) -> int:
	var b := _builder
	var face_c := _palette.color(face)
	var border := _palette.color(look.sign_border_color)
	var post := _palette.color(look.post_color)
	for dist in inst.def.warning_sign_distances_m:
		if line + 1 >= sl.lines.size():
			break
		var s := inst.warn_s - dist
		var d0 := road.guardrail_d(s) + look.sign_setback_m
		var d1 := d0 + look.sign_width_m
		var h0 := look.sign_bottom_m
		var h1 := h0 + look.sign_height_m
		var bd := look.sign_border_m
		var hm := h1 - bd - (look.sign_height_m - 2.0 * bd) * look.sign_big_line_frac
		atlas.draw(sl.lines[line], words)
		atlas.draw(sl.lines[line + 1], LandmarkText.distance(dist))
		# Border (back plate), then the two text lines on the face in front of it.
		var back := s + look.sign_depth_m
		b.box(s, back, d0, d1, h0, h1, border, SetPieceMeshBuilder.EMISSIVE_NONE, border, SetPieceMeshBuilder.EMISSIVE_REFLECTOR)
		var fs := s - look.sign_depth_m * 0.5
		b.panel(fs, d0 + bd, d1 - bd, hm, h1 - bd, face_c, SetPieceMeshBuilder.EMISSIVE_REFLECTOR, atlas.uv_rect(sl.lines[line]))
		b.panel(fs, d0 + bd, d1 - bd, h0 + bd, hm, face_c, SetPieceMeshBuilder.EMISSIVE_REFLECTOR,
			atlas.uv_rect(sl.lines[line + 1]))
		var pw := look.sign_post_width_m
		for dp: float in [d0 + look.sign_width_m * 0.25, d1 - look.sign_width_m * 0.25]:
			b.box(back, back + pw, dp - pw * 0.5, dp + pw * 0.5, 0.0, h1, post)
		line += 2
	return line


## Road works: the barrier segments, the arrow board on its trailer; the cones go to the
## MultiMesh.
func _works(sl: Slot, inst: SetPieceSource.Instance) -> void:
	var w := inst.controller as RoadWorksPiece
	var d := inst.def
	var b := _builder
	# Barrier: segments with retro-reflective red and white faces toward traffic.
	var white := _palette.color(look.barrier_color)
	var red := _palette.color(look.barrier_stripe_color)
	var hw := d.barrier_width_m * 0.5
	var s := w.barrier_s0
	var k := 0
	while s < w.barrier_s1 - look.barrier_gap_m:
		var e := minf(s + look.barrier_segment_m, w.barrier_s1)
		var c := red if k % 2 == 0 else white
		b.box(s, e, w.barrier_d - hw, w.barrier_d + hw, 0.0, look.barrier_height_m, c,
			SetPieceMeshBuilder.EMISSIVE_REFLECTOR)
		s = e + look.barrier_gap_m
		k += 1
	# Arrow board: a trailer, a black board on it framed in retro yellow, amber lamps.
	var bw := d.arrow_board_width_m * 0.5
	var bl := d.arrow_board_length_m
	var s0 := w.arrow_s - bl * 0.5
	var trailer := _palette.color(look.trailer_color)
	b.box(s0, s0 + bl, w.arrow_d - bw, w.arrow_d + bw, 0.0, look.trailer_height_m, trailer)
	var h0 := look.board_bottom_m
	var h1 := h0 + look.board_height_m
	var frame := _palette.color(look.board_frame_color)
	b.box(s0, s0 + look.board_depth_m, w.arrow_d - bw, w.arrow_d + bw, h0, h1, frame,
		SetPieceMeshBuilder.EMISSIVE_REFLECTOR)
	var fb := look.board_depth_m * 0.5
	var inset := look.sign_border_m * 2.0
	b.panel(s0 - fb * 0.1, w.arrow_d - bw + inset, w.arrow_d + bw - inset, h0 + inset, h1 - inset,
		_palette.color(look.board_color), SetPieceMeshBuilder.EMISSIVE_NONE)
	b.box(s0 + look.board_depth_m, s0 + bl * 0.5, w.arrow_d - look.sign_post_width_m, w.arrow_d + look.sign_post_width_m,
		look.trailer_height_m, h0, _palette.color(look.post_color))
	_arrow(s0 - fb * 0.2, w.arrow_d, (h0 + h1) * 0.5, bw - inset * 2.0, (h1 - h0) * 0.5 - inset * 2.0, -w.side)
	sl.flashes = true
	sl.flash_hz = d.arrow_flash_hz
	_fill_cones(inst, w)


## The arrow: a shaft of lamps and a head, pointing `dir` (-1 left, +1 right), centred
## at (d, h) within half extents (hw, hh), on the board's face at s.
func _arrow(s: float, d: float, h: float, hw: float, hh: float, dir: int) -> void:
	var amber := _palette.color(look.arrow_color)
	var lamp := hh * 0.3
	var n := 5
	for k in n:
		var x := lerpf(-hw * 0.8, hw * 0.55, float(k) / float(n - 1)) * float(dir)
		_lamp(s, d + x, h, lamp, amber)
	for k in 2:
		var t := float(k + 1)
		var x := (hw * 0.55 - lamp * 1.4 * t) * float(dir)
		_lamp(s, d + x, h + lamp * 1.4 * t, lamp, amber)
		_lamp(s, d + x, h - lamp * 1.4 * t, lamp, amber)


func _lamp(s: float, d: float, h: float, r: float, c: Color) -> void:
	_builder.panel(s, d - r * 0.5, d + r * 0.5, h - r * 0.5, h + r * 0.5, c, SetPieceMeshBuilder.EMISSIVE_FLASH)


func _fill_cones(inst: SetPieceSource.Instance, w: RoadWorksPiece) -> void:
	var mm := cones.multimesh
	var n := mini(w.cone_s.size(), look.max_cones)
	var smp := RoadSample.new()
	road.sample_into(inst.zone_s0, smp)
	_cone_anchor[0] = smp.pos_x
	_cone_anchor[1] = smp.pos_y
	_cone_anchor[2] = smp.pos_z
	for i in n:
		road.sample_into(w.cone_s[i], smp)
		var p := smp.local_point(w.cone_d[i], _cone_anchor[0], _cone_anchor[1], _cone_anchor[2])
		var frame := Basis(smp.right, smp.up, -smp.tangent)
		mm.set_instance_transform(i, Transform3D(frame, p))
	mm.visible_instance_count = n
	cones_serial = inst.serial
	_place(cones, _cone_anchor[0], _cone_anchor[1], _cone_anchor[2])
	cones.visible = true


## Merge zone: the on-ramp ribbon from the right with its edge lines and outer rail, the
## gore between it and the mainline shoulder (hatched near the nose), the rail
## attenuator at the nose.
func _ramp(inst: SetPieceSource.Instance) -> void:
	var mz := inst.controller as MergeZonePiece
	var d := inst.def
	var b := _builder
	var road_c := Color.WHITE
	var line_c := Color.WHITE
	var rail_c := _palette.color(&"steel")
	var nose := mz.nose_s
	var seg := look.ramp_segment_m
	var lift := look.lift_m
	var rw := look.ramp_width_m
	var lw := look.ramp_line_width_m
	var s := nose - d.ramp_length_m
	while s < mz.join_end_s - 1e-3:
		var e := minf(s + seg, mz.join_end_s)
		var a_in := _ramp_inner(mz, d, s)
		var e_in := _ramp_inner(mz, d, e)
		b.strip(s, e, a_in, a_in + rw, e_in, e_in + rw, lift, road_c, SetPieceMeshBuilder.TINT_ROAD, seg)
		b.strip(s, e, a_in + lw, a_in + lw * 2.0, e_in + lw, e_in + lw * 2.0, lift * 1.5, line_c,
			SetPieceMeshBuilder.TINT_LINE, seg)
		b.strip(s, e, a_in + rw - lw * 2.0, a_in + rw - lw, e_in + rw - lw * 2.0, e_in + rw - lw, lift * 1.5, line_c,
			SetPieceMeshBuilder.TINT_LINE, seg)
		# Outer rail on its posts' line.
		var ra := a_in + rw + road.guardrail_offset_m
		var re := e_in + rw + road.guardrail_offset_m
		_rail(s, e, ra, re, rail_c)
		# Gore: hatch stripes across the gap to the mainline shoulder near the nose.
		var gap := a_in - road.shoulder_outer_d(s)
		if s >= nose - d.ramp_length_m * 0.5 and gap > 0.0 and fposmod(s - nose, look.gore_stripe_every_m) < seg:
			var g0 := road.shoulder_outer_d(s)
			b.strip(s, s + look.gore_stripe_width_m, g0, a_in, g0, a_in, lift * 1.5, line_c, SetPieceMeshBuilder.TINT_LINE,
				look.gore_stripe_width_m)
		s = e
	# The attenuator at the nose, on the mainline rail's line.
	var g := road.guardrail_d(nose)
	var al := look.attenuator_length_m
	var aw := look.attenuator_width_m * 0.5
	b.box(nose - al, nose, g - aw, g + aw, 0.0, look.attenuator_height_m, _palette.color(look.attenuator_color),
		SetPieceMeshBuilder.EMISSIVE_REFLECTOR, _palette.color(look.attenuator_stripe_color),
		SetPieceMeshBuilder.EMISSIVE_REFLECTOR)


## The ramp's inner edge d at s: ramp_gap_m beyond the mainline rail at the nose,
## curving away upstream (slope x + curve x^2), then over the join taper sliding onto
## the new lane (the road's right edge at the join's end).
func _ramp_inner(mz: MergeZonePiece, d: SetPieceDef, s: float) -> float:
	var base := road.guardrail_d(mz.nose_s) + d.ramp_gap_m
	if s <= mz.nose_s:
		var x := mz.nose_s - s
		return base + d.ramp_slope * x + d.ramp_curve_per_m * x * x
	var u := clampf((s - mz.nose_s) / maxf(mz.join_end_s - mz.nose_s, 1e-3), 0.0, 1.0)
	var w := road.lane_width(mz.join_end_s)
	var target := road.lanes_right_edge_d(mz.join_end_s) - w - (look.ramp_width_m - w) * 0.5
	return lerpf(base, target, u * u * (3.0 - 2.0 * u))


func _rail(s: float, e: float, da: float, de: float, c: Color) -> void:
	var b := _builder
	var h1 := look.rail_height_m
	var h0 := h1 - look.rail_depth_m
	var p0 := b.point(s, da, h0)
	var p1 := b.point(e, de, h0)
	var p2 := b.point(e, de, h1)
	var p3 := b.point(s, da, h1)
	b.quad(p0, p1, p2, p3, -b.right_at((s + e) * 0.5), c)
	b.quad(p0, p1, p2, p3, b.right_at((s + e) * 0.5), c)


## Toll gantry: TOLL painted in the booth lanes, EXPRESS in the express lanes.
func _legends(sl: Slot, inst: SetPieceSource.Instance, line: int) -> void:
	var tg := inst.controller as TollGantryPiece
	var s1 := tg.checkpoint_s - look.legend_before_m
	var s0 := s1 - look.legend_length_m
	var paint := Color.WHITE
	atlas.draw(sl.lines[line], "TOLL")
	atlas.draw(sl.lines[line + 1], "EXPRESS")
	var w := road.lane_width(s0)
	var half := w * look.legend_width_frac * 0.5
	for lane in inst.lanes:
		var c := road.lane_center_d(lane, s0)
		var r := atlas.uv_rect(sl.lines[line] if tg.is_booth_lane(lane) else sl.lines[line + 1])
		_builder.legend(s0, s1, c - half, c + half, look.lift_m, paint, r)
	sl.s0 = minf(sl.s0, s0)


func _place(n: Node3D, ax: float, ay: float, az: float) -> void:
	if origin != null:
		n.position = Vector3(ax - origin.origin_x, ay - origin.origin_y, az - origin.origin_z)
	else:
		n.position = Vector3(ax, ay, az)
	n.reset_physics_interpolation()


func _on_origin_shifted(_offset: Vector3) -> void:
	for sl in slots:
		if sl.serial >= 0:
			_place(sl.node, sl.anchor_x, sl.anchor_y, sl.anchor_z)
	if cones_serial >= 0:
		_place(cones, _cone_anchor[0], _cone_anchor[1], _cone_anchor[2])


func _enter_tree() -> void:
	if not _connected and Events.has_signal(&"origin_shifted"):
		Events.origin_shifted.connect(_on_origin_shifted)
		_connected = true


func _exit_tree() -> void:
	if _connected:
		Events.origin_shifted.disconnect(_on_origin_shifted)
		_connected = false
