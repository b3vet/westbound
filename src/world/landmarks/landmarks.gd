class_name Landmarks
extends Node3D
## Checkpoint landmarks and their warning signs (WP5.3). Spec: Core loop → Legs and
## checkpoints ("each [leg] ending at a checkpoint landmark: express toll gantry,
## suspension bridge, big sign gantry, or tunnel portal"; "warning signs announce each
## checkpoint at 1 km and 500 m"), World → Checkpoint landmarks ("big sign gantry with
## the leg name and distance"; "announced by signs at 1 km and 500 m"), Night
## lighting (retro-reflective signs), Performance budget (draw calls, no lights).
##
## World-system node (docs/CONTRACTS.md §13):
##   landmarks.biome_director = director    # optional: landmark style + leg names
##   landmarks.setup(ctx, road, origin)
##   landmarks.update_view(player_s)         # once per frame
##
## Each CHECKPOINT feature gets the build of its style (feature tag, which the biome
## director fills from the biome whose leg ends there, else `default_style`) AT the
## checkpoint line, and
## each SIGN feature tagged ProceduralRoadPath.SIGN_CHECKPOINT a roadside panel on the
## right. Everything is pooled: every kind is built once at warm-up (per road
## cross-section) and drawn by `landmarks_per_kind_count` MeshInstance3Ds, signs by
## `sign_pool_count`; nothing is created after setup. One surface per instance, so a
## landmark and two signs in view cost 3 draw calls.
##
## Long builds bend along the road in landmark.gdshader through stations sampled once
## at placement, relative to the build's 64-bit anchor (the road at the checkpoint);
## the node sits at anchor - origin and simply moves on Events.origin_shifted.
##
## Roadside clearance (WP5.5): `clearance` (LandmarkClearance) knows every build's and
## sign's ground zones from the road features and the tuning alone, before anything is
## placed; `exclusion_zones(s0, s1, out)` lists them. Roadside and StreetLampPools keep
## their own LandmarkClearance with the same inputs, so they skip the same props.

const KIND_SIGN := LandmarkBuilds.KIND_SIGN
const SHADER := preload("res://src/world/landmarks/landmark.gdshader")
## Must match landmark.gdshader STATION_MAX / LINE_MAX.
const STATION_MAX := 80
const LINE_MAX := LandmarkMeshBuilder.MAX_LINES
## A feature this close to a placed one is the same checkpoint or sign.
const SAME_S_M := 0.5   # lint: allow-number tolerance on feature positions, not tuning

## One pooled instance.
class Slot:
	extends RefCounted
	var kind: StringName
	var node: MeshInstance3D
	var material: ShaderMaterial
	var template: LandmarkTemplate
	## Atlas region per text line.
	var regions := PackedInt32Array()
	var live: bool = false
	## Checkpoint s (landmarks) or sign s (signs).
	var s: float = 0.0
	## The leg ending at this checkpoint (the checkpoint a sign announces).
	var leg: int = 0
	## Signs: the distance announced (m).
	var distance_m: float = 0.0
	var anchor_x: float = 0.0
	var anchor_y: float = 0.0
	var anchor_z: float = 0.0
	## Signs: lateral offset of the node from the reference line.
	var d: float = 0.0
	var stations := PackedVector4Array()
	var station_count: int = 0
	var station_s0: float = 0.0
	var station_step: float = 1.0
	var lines := PackedStringArray()


## Set before setup: landmark style of the leg's biome and the next leg's name.
var biome_director: BiomeDirector
## Style when neither the feature nor a biome gives one.
var default_style: StringName = LandmarkClearance.DEFAULT_STYLE
## Non-empty: every checkpoint uses this style (previews, dev).
var style_override: StringName = &""
## > 0 overrides Quality.view_distance_m (previews, tests).
var view_distance_override_m: float = 0.0
## Tuning (LandmarkTuning.load_default() when null at setup).
var tuning: LandmarkTuning

var slots: Array[Slot] = []
var atlas: LandmarkTextAtlas
## The builds' and signs' ground zones (built at setup).
var clearance: LandmarkClearance
## Placements that found no free slot of their kind (sizing error; tests assert 0).
var dropped: int = 0
## Window of the last feature query (tests, previews).
var window_s_lo: float = 0.0
var window_s_hi: float = 0.0

## Builds per (kind, cross-section key), shared by every Landmarks node and kept
## across retries (they only depend on tuning and the cross-section).
static var _template_cache: Dictionary = {}

var _road: RoadPath
var _origin: FloatingOrigin
var _quality: QualityTuning
var _leg_length_m: float = 0.0
var _palette: WBPalette
var _step_index: int = -1
var _refresh: bool = true
var _connected: bool = false
var _features: Array[RoadFeature] = []
var _sample := RoadSample.new()


func setup(ctx: RunContext, road: RoadPath, origin: FloatingOrigin) -> void:
	_road = road
	_origin = origin
	_quality = ctx.tuning.quality
	_leg_length_m = ctx.tuning.legs.leg_length_m()
	if tuning == null:
		tuning = ctx.tuning.get(&"landmarks") as LandmarkTuning
	if tuning == null:
		tuning = LandmarkTuning.load_default()
	if _palette == null:
		_palette = WBPalette.load_default()
	clearance = LandmarkClearance.new()
	clearance.default_style = default_style
	clearance.setup(road, tuning, biome_director, style_override)
	if slots.is_empty():
		_warm_up(LandmarkSection.at(road, 0.0))
	for slot in slots:
		_release(slot)
	dropped = 0
	_step_index = -1
	_refresh = true
	_connect()


## Once per frame with the focus (player) s. Re-queries features only when the focus
## moved a step (or after setup / a quality change).
func update_view(focus_s: float) -> void:
	if _road == null:
		return
	var k := int(floor(focus_s / tuning.update_step_m))
	if k == _step_index and not _refresh:
		return
	_step_index = k
	_refresh = false
	_update_window(focus_s)


## Current view distance: the override, else the Quality tier (+ governor).
func view_distance_m() -> float:
	if view_distance_override_m > 0.0:
		return view_distance_override_m
	var q: float = Quality.view_distance_m
	if q > 0.0:
		return q
	var i := maxi(_quality.tier_names.find(String(_quality.default_tier)), 0)
	return _quality.view_distance_m[i]


## The style a checkpoint feature gets.
func style_for(f: RoadFeature) -> StringName:
	return LandmarkClearance.resolve_style(f, biome_director, style_override, default_style)


## The ground zones of every landmark and warning sign touching [s0, s1] (ZONE_FLOATS
## each: s from, s to, d from, d to, floor height; LandmarkBuilds.clearance_zones), the
## margin included. Available after setup, before anything is placed. Director rate.
func exclusion_zones(s0: float, s1: float, out: PackedFloat64Array) -> void:
	if clearance != null:
		clearance.zones_in(s0, s1, out)


# ---------------------------------------------------------------- Stats (dev HUD, previews, tests)

func live_slots() -> Array[Slot]:
	var out: Array[Slot] = []
	for slot in slots:
		if slot.live:
			out.append(slot)
	return out


## Visible instances (one surface each: one draw call each when in the frustum).
func draw_calls() -> int:
	var n := 0
	for slot in slots:
		if slot.live:
			n += slot.node.mesh.get_surface_count()
	return n


func triangles() -> int:
	var n := 0
	for slot in slots:
		if slot.live:
			n += slot.template.triangles
	return n


func find_live(kind: StringName, s: float) -> Slot:
	for slot in slots:
		if slot.live and slot.kind == kind and absf(slot.s - s) < SAME_S_M:
			return slot
	return null


## Template point `v` of a live slot in render space (the CPU mirror of the shader's
## bend plus the node transform; tests, bounds).
func render_point(slot: Slot, v: Vector3) -> Vector3:
	return slot.node.transform * local_point(slot, v)


## Template point `v` in the slot's node space (the shader's bend).
func local_point(slot: Slot, v: Vector3) -> Vector3:
	if slot.station_count < 2:
		return v
	var f := (-v.z - slot.station_s0) / slot.station_step
	var i := clampi(int(floor(f)), 0, slot.station_count - 2)
	var t := f - float(i)
	var a := slot.stations[i]
	var b := slot.stations[i + 1]
	var base := Vector3(lerpf(a.x, b.x, t), lerpf(a.y, b.y, t), lerpf(a.z, b.z, t))
	var h := lerpf(a.w, b.w, t)
	return base + Vector3(cos(h), 0.0, sin(h)) * v.x + Vector3(0.0, v.y, 0.0)


# ---------------------------------------------------------------- Window

func _update_window(focus_s: float) -> void:
	var lo := focus_s - tuning.keep_behind_m
	var hi := focus_s + view_distance_m() + tuning.place_margin_m
	window_s_lo = lo
	window_s_hi = hi
	var gen := _road.length_generated()
	for slot in slots:
		if slot.live and (slot.s + slot.template.s_after < lo or slot.s - slot.template.s_before > hi):
			_release(slot)
	var reach_before := 0.0
	var reach_after := 0.0
	for slot in slots:
		reach_before = maxf(reach_before, slot.template.s_before)
		reach_after = maxf(reach_after, slot.template.s_after)
	_features.clear()
	_road.features_in(maxf(0.0, lo - reach_after), hi + reach_before, _features)
	if biome_director != null:
		biome_director.tag_checkpoints(_features)
	for f in _features:
		if f.kind == RoadFeature.Kind.CHECKPOINT:
			var kind := style_for(f)
			var cp := f.s_start
			var tpl := _template_at(kind, cp)
			if cp - tpl.s_before > hi or cp + tpl.s_after < lo or find_live(kind, cp) != null:
				continue
			if cp - tpl.s_before < _first_sampleable_s():
				continue   # already forgotten behind (a teleport): skip it
			if cp + tpl.s_after > gen:
				# Director rate, like RoadBuilder: the table does not depend on how far ahead
				# or in what steps it is generated.
				_road.ensure_generated_to(cp + tpl.s_after)
				gen = _road.length_generated()
				if cp + tpl.s_after > gen:
					continue
			var slot := _acquire(kind)
			if slot == null:
				dropped += 1
				continue
			_place_landmark(slot, f)
		elif f.kind == RoadFeature.Kind.SIGN and f.tag == ProceduralRoadPath.SIGN_CHECKPOINT:
			var s := f.s_start
			if s > hi or s < lo or find_live(KIND_SIGN, s) != null:
				continue
			var slot := _acquire(KIND_SIGN)
			if slot == null:
				dropped += 1
				continue
			_place_sign(slot, f)
	atlas.commit()


func _first_sampleable_s() -> float:
	if _road is ProceduralRoadPath:
		return (_road as ProceduralRoadPath).first_retained_s()
	return -INF


func _acquire(kind: StringName) -> Slot:
	for slot in slots:
		if not slot.live and slot.kind == kind:
			return slot
	return null


func _release(slot: Slot) -> void:
	slot.live = false
	slot.node.visible = false


# ---------------------------------------------------------------- Placement

func _place_landmark(slot: Slot, f: RoadFeature) -> void:
	var cp := f.s_start
	var tpl := _template_at(slot.kind, cp)
	if slot.template != tpl:
		_bind(slot, tpl)
	slot.s = cp
	slot.leg = int(f.value)
	_road.sample_into(cp, _sample)
	slot.anchor_x = _sample.pos_x
	slot.anchor_y = _sample.pos_y
	slot.anchor_z = _sample.pos_z
	# Stations along the build's whole length, relative to the anchor.
	var length := tpl.s_before + tpl.s_after
	var step := maxf(tuning.bend_station_step_m, length / float(STATION_MAX - 1))
	var n := clampi(int(ceil(length / step)) + 1, 2, STATION_MAX)
	slot.station_count = n
	slot.station_s0 = -tpl.s_before
	slot.station_step = step
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	var prev_h := 0.0
	for i in n:
		_road.sample_into(cp + slot.station_s0 + float(i) * step, _sample)
		var h := _sample.heading
		if i > 0:
			h = prev_h + wrapf(h - prev_h, -PI, PI)
		prev_h = h
		var p := Vector3(_sample.pos_x - slot.anchor_x, _sample.pos_y - slot.anchor_y, _sample.pos_z - slot.anchor_z)
		slot.stations[i] = Vector4(p.x, p.y, p.z, h)
		lo = lo.min(p)
		hi = hi.max(p)
	var m := slot.material
	m.set_shader_parameter(&"stations", slot.stations)
	m.set_shader_parameter(&"station_count", n)
	m.set_shader_parameter(&"station_s0", slot.station_s0)
	m.set_shader_parameter(&"station_inv_step", 1.0 / step)
	var r := tpl.max_abs_x
	slot.node.custom_aabb = AABB(Vector3(lo.x - r, lo.y + tpl.min_y, lo.z - r),
		Vector3(hi.x - lo.x + 2.0 * r, hi.y - lo.y + tpl.max_y - tpl.min_y, hi.z - lo.z + 2.0 * r))
	slot.node.transform = Transform3D(Basis.IDENTITY, _origin.to_local(slot.anchor_x, slot.anchor_y, slot.anchor_z))
	var next_name := _biome_name_at(cp + SAME_S_M)
	_set_lines(slot, LandmarkText.landmark(slot.kind, slot.leg, next_name, _next_checkpoint_distance(cp)))
	_show(slot)


func _place_sign(slot: Slot, f: RoadFeature) -> void:
	var s := f.s_start
	slot.s = s
	slot.distance_m = f.value
	var cp := s + f.value
	slot.leg = _leg_at_checkpoint(cp)
	_road.sample_into(s, _sample)
	slot.d = _road.guardrail_d(s) + tuning.sign_setback_m
	slot.anchor_x = _sample.pos_x + _sample.right.x * slot.d
	slot.anchor_y = _sample.pos_y + _sample.right.y * slot.d
	slot.anchor_z = _sample.pos_z + _sample.right.z * slot.d
	slot.station_count = 0
	slot.node.transform = Transform3D(Basis(Vector3.UP, _sample.godot_yaw(0.0)),
		_origin.to_local(slot.anchor_x, slot.anchor_y, slot.anchor_z))
	_set_lines(slot, LandmarkText.warning_sign(f.value, slot.leg + 1, _biome_name_at(cp + SAME_S_M)))
	_show(slot)


func _show(slot: Slot) -> void:
	slot.live = true
	slot.node.visible = true
	slot.node.reset_physics_interpolation()


func _set_lines(slot: Slot, lines: PackedStringArray) -> void:
	slot.lines = lines
	for i in slot.regions.size():
		atlas.draw(slot.regions[i], lines[i] if i < lines.size() else "")


## The leg ending at the checkpoint at `cp` (the feature's value when it is known).
func _leg_at_checkpoint(cp: float) -> int:
	for f in _features:
		if f.kind == RoadFeature.Kind.CHECKPOINT and absf(f.s_start - cp) < SAME_S_M:
			return int(f.value)
	return maxi(1, roundi(cp / _leg_length_m)) if _leg_length_m > 0.0 else 1


## Distance from the checkpoint at `cp` to the next one (road features when
## generated that far, else the leg length).
func _next_checkpoint_distance(cp: float) -> float:
	var found: Array[RoadFeature] = []
	_road.features_in(cp + SAME_S_M, cp + _leg_length_m * 2.0, found)
	for f in found:
		if f.kind == RoadFeature.Kind.CHECKPOINT:
			return f.s_start - cp
	return _leg_length_m


func _biome_name_at(s: float) -> String:
	if biome_director == null:
		return ""
	var b := biome_director.biome_at(s)
	return b.display_name if b != null else ""


# ---------------------------------------------------------------- Pools

func _warm_up(section: LandmarkSection) -> void:
	atlas = LandmarkTextAtlas.new(tuning)
	var ink := _palette.color(&"white")
	for kind in LandmarkBuilds.kinds():
		var tpl := _build_template(kind, section)
		for i in tuning.landmarks_per_kind_count:
			slots.append(_new_slot(kind, tpl, ink, "%s_%d" % [kind, i]))
	var sign_tpl := _build_template(KIND_SIGN, section)
	for i in tuning.sign_pool_count:
		slots.append(_new_slot(KIND_SIGN, sign_tpl, ink, "sign_%d" % i))
	atlas.commit()


func _new_slot(kind: StringName, tpl: LandmarkTemplate, ink: Color, node_name: String) -> Slot:
	var slot := Slot.new()
	slot.kind = kind
	slot.stations.resize(STATION_MAX)
	slot.material = ShaderMaterial.new()
	slot.material.shader = SHADER
	slot.material.set_shader_parameter(&"text_atlas", atlas.texture)
	slot.material.set_shader_parameter(&"text_color", Vector3(ink.r, ink.g, ink.b))
	slot.material.set_shader_parameter(&"retro_emissive_gain", tuning.retro_emissive_factor)
	slot.material.set_shader_parameter(&"retro_light_gain", tuning.retro_light_factor)
	slot.material.set_shader_parameter(&"retro_day_fill", tuning.retro_day_fill_frac)
	slot.node = MeshInstance3D.new()
	slot.node.name = node_name
	slot.node.material_override = slot.material
	slot.node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	slot.node.visible = false
	add_child(slot.node)
	_bind(slot, tpl)
	# Regions for the most lines any build of this kind has.
	var rects := PackedVector4Array()
	rects.resize(LINE_MAX)
	for i in tpl.line_count():
		slot.regions.append(atlas.alloc(tpl.line_aspect[i]))
		rects[i] = atlas.uv_rect(slot.regions[i])
	slot.material.set_shader_parameter(&"line_rect", rects)
	return slot


func _bind(slot: Slot, tpl: LandmarkTemplate) -> void:
	slot.template = tpl
	slot.node.mesh = tpl.mesh


## The build of `kind` for the road's cross-section at `s` (the warm-up build unless
## the lane count differs there: then built once and cached).
func _template_at(kind: StringName, s: float) -> LandmarkTemplate:
	return _build_template(kind, LandmarkSection.at(_road, s))


func _build_template(kind: StringName, section: LandmarkSection) -> LandmarkTemplate:
	# Signs are placed from the guardrail at their own s: one build for every section.
	var key := "" if kind == KIND_SIGN else section.key()
	var cache_key := "%s|%s|%d" % [kind, key, tuning.get_instance_id()]
	if not _template_cache.has(cache_key):
		_template_cache[cache_key] = LandmarkBuilds.build(kind, section, tuning, _palette)
	return _template_cache[cache_key]


# ---------------------------------------------------------------- Floating origin

func _connect() -> void:
	if _connected:
		return
	Events.origin_shifted.connect(_on_origin_shifted)
	Events.quality_changed.connect(_on_quality_changed)
	Events.governor_changed.connect(_on_governor_changed)
	_connected = true


func _disconnect() -> void:
	if not _connected:
		return
	Events.origin_shifted.disconnect(_on_origin_shifted)
	Events.quality_changed.disconnect(_on_quality_changed)
	Events.governor_changed.disconnect(_on_governor_changed)
	_connected = false


func _enter_tree() -> void:
	if _road != null:
		_connect()


func _exit_tree() -> void:
	_disconnect()


func _on_origin_shifted(_offset: Vector3) -> void:
	for slot in slots:
		if slot.live:
			slot.node.position = _origin.to_local(slot.anchor_x, slot.anchor_y, slot.anchor_z)
			slot.node.reset_physics_interpolation()


func _on_quality_changed(_tier: StringName) -> void:
	_refresh = true


func _on_governor_changed(_rung: int) -> void:
	_refresh = true
