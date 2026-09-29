class_name HeadlightCones
extends Node3D
# lint: not-sim Node adapter that draws light decals from TrafficState read-only; it simulates nothing
## Traffic headlight cones on the road (WP5.4). Spec: World → Night lighting
## ("Traffic headlights: emissive quads, additive glow sprites and a light-cone decal
## on the road"); Performance budget (road decals, draw calls, transparency: minimal
## overdraw, counts per tier). docs/NIGHT.md.
##
##   cones.setup(ctx, road, origin)                  # world-system API (CONTRACTS §13)
##   cones.sky = sky
##   cones.bind(traffic_view, sim.state, director.opposite.state)
##   cones.update_view(player_s)                     # once per frame
##
## One MultiMesh (1 draw call) of flat trapezoids ahead of the front bumper of the
## nearest vehicles with their headlights on (TrafficState.FLAG_HEADLIGHTS), on both
## carriageways, within NightTuning.traffic_cone_range_m of the player along the road.
## At most NightTuning.traffic_cones_per_tier[tier] are drawn (the Quality tier, or
## `tier_index_override`); cones fade out over the last traffic_cone_fade_m of the
## range. Each cone uses the vehicle's drawn pose (TrafficView.slot_transform at the
## frame's physics interpolation fraction), so it moves exactly with the body.
## Additive, fogged and ramped by the color script's headlight ramp
## (assets/shaders/light_decal.gdshader, materials/traffic_cone.tres). Hidden (no
## draw call) while the ramp is below NightTuning.visible_min_ramp or no cone is due.
## The glow pass's own per-vehicle pools are turned off where this node runs
## (TrafficView.headlight_pools = false).
##
## Allocation-free per frame: the selection uses preallocated packed arrays (an
## insertion into the sorted nearest-N list) and writes MultiMesh instances in place.

const MATERIAL := preload("res://assets/shaders/materials/traffic_cone.tres")
const CARRIAGEWAY := 0
const OPPOSITE := 1

## Night numbers; defaults to Tuning.night when it exists, else NightTuning.load_default().
var tuning: NightTuning
## Reads the headlight ramp (SkyRig.current().emissive_headlight). Null = always off.
var sky: SkyRig
var view: TrafficView
## >= 0: use this quality tier index instead of the Quality autoload's (tests, previews).
var tier_index_override: int = -1
## >= 0: this physics interpolation fraction instead of the engine's (tests).
var fraction_override: float = -1.0
## The headlight ramp read last frame.
var ramp: float = 0.0

var _states: Array[TrafficState] = []
var _mm: MultiMesh
var _mmi: MultiMeshInstance3D
## Instance capacity: the largest per-tier cap.
var _capacity: int = 0
var _count: int = 0
# Nearest-N selection, sorted by distance (preallocated to _capacity).
var _sel_side := PackedInt32Array()
var _sel_slot := PackedInt32Array()
var _sel_dist := PackedFloat64Array()
var _sel_n: int = 0
## CPU copies of the instances (the source of truth for tests and tools; a headless
## renderer keeps no MultiMesh data).
var _xf: Array[Transform3D] = []
var _strength := PackedFloat32Array()


func _init() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF


## World-system API (CONTRACTS §13). Builds the MultiMesh once.
func setup(ctx: RunContext, _road: RoadPath, _origin: FloatingOrigin) -> void:
	if tuning == null:
		var t: Variant = ctx.tuning.get(&"night") if ctx != null and ctx.tuning != null else null
		tuning = t as NightTuning if t is NightTuning else NightTuning.load_default()
	if _mmi == null:
		_build()


## The view whose poses the cones follow, and the carriageways it draws.
func bind(traffic_view: TrafficView, carriageway: TrafficState, opposite: TrafficState = null) -> void:
	view = traffic_view
	_states.clear()
	_states.append(carriageway)
	if opposite != null:
		_states.append(opposite)
	_count = 0
	_mm.visible_instance_count = 0
	_mmi.visible = false


## World-system API: once per frame with the player's s.
func update_view(focus_s: float) -> void:
	ramp = sky.current().emissive_headlight if sky != null else 0.0
	_count = 0
	if view != null and not _states.is_empty() and is_finite(ramp) and ramp >= tuning.visible_min_ramp:
		_select(focus_s, cap())
		_write()
	if _mm.visible_instance_count != _count:
		_mm.visible_instance_count = _count
	var lit := _count > 0
	if _mmi.visible != lit:
		_mmi.visible = lit


## Cones allowed at the current quality tier.
func cap() -> int:
	return mini(tuning.traffic_cones_for_tier(tier_index()), _capacity)


func tier_index() -> int:
	if tier_index_override >= 0:
		return tier_index_override
	var q := get_node_or_null(^"/root/Quality") if is_inside_tree() else null
	if q != null:
		var eff: Object = q.get(&"effective")
		if eff != null:
			return int(eff.get(&"tier_index"))
	var qt := Tuning.load_default().quality
	return maxi(qt.tier_index(qt.default_tier), 0)


## Cones drawn this frame.
func count() -> int:
	return _count


func capacity() -> int:
	return _capacity


## Draw calls this frame (0 or 1).
func draw_calls() -> int:
	return 1 if _mmi.visible and _count > 0 else 0


## Slot and carriageway (CARRIAGEWAY / OPPOSITE) of cone `k` (nearest first).
func cone_slot(k: int) -> int:
	return _sel_slot[k]


func cone_side(k: int) -> int:
	return _sel_side[k]


func cone_transform(k: int) -> Transform3D:
	return _xf[k]


func cone_strength(k: int) -> float:
	return _strength[k]


func multimesh() -> MultiMesh:
	return _mm


func node() -> MultiMeshInstance3D:
	return _mmi


# ---------------------------------------------------------------- Internals

## The `n` nearest drawn vehicles with headlights on, within range, sorted by |ds|.
func _select(focus_s: float, n: int) -> void:
	_sel_n = 0
	if n <= 0:
		return
	var range_m := tuning.traffic_cone_range_m
	for side in _states.size():
		var st := _states[side]
		var opposite := side == OPPOSITE
		for i in st.capacity:
			if st.active[i] == 0 or (st.flags[i] & TrafficState.FLAG_HEADLIGHTS) == 0:
				continue
			var dist := absf(st.s[i] - focus_s)
			if dist > range_m:
				continue
			if _sel_n == n and dist >= _sel_dist[n - 1]:
				continue
			if not view.is_slot_drawn(i, opposite):
				continue
			# Insertion into the sorted list (drops the farthest when full).
			var k := mini(_sel_n, n - 1)
			while k > 0 and _sel_dist[k - 1] > dist:
				_sel_dist[k] = _sel_dist[k - 1]
				_sel_slot[k] = _sel_slot[k - 1]
				_sel_side[k] = _sel_side[k - 1]
				k -= 1
			_sel_dist[k] = dist
			_sel_slot[k] = i
			_sel_side[k] = side
			if _sel_n < n:
				_sel_n += 1


func _write() -> void:
	var f := fraction_override if fraction_override >= 0.0 else Engine.get_physics_interpolation_fraction()
	var range_m := tuning.traffic_cone_range_m
	var fade := maxf(tuning.traffic_cone_fade_m, 0.001)
	for k in _sel_n:
		var side := _sel_side[k]
		var slot := _sel_slot[k]
		var xf := view.slot_transform(slot, side == OPPOSITE, f)
		var st := _states[side]
		# The cone starts at the front bumper (the model origin is the body center).
		var fwd := -xf.basis.z
		var o := xf.origin + fwd * (st.length[slot] * 0.5) + xf.basis.y * tuning.traffic_cone_lift_m
		_xf[k] = Transform3D(xf.basis, o)
		_strength[k] = clampf((range_m - _sel_dist[k]) / fade, 0.0, 1.0)
		_mm.set_instance_transform(k, _xf[k])
		_mm.set_instance_custom_data(k, Color(_strength[k], 0.0, 0.0, 0.0))
	_count = _sel_n


func _build() -> void:
	_capacity = 0
	for c in tuning.traffic_cones_per_tier:
		_capacity = maxi(_capacity, c)
	_sel_side.resize(_capacity)
	_sel_slot.resize(_capacity)
	_sel_dist.resize(_capacity)
	_xf.resize(_capacity)
	_strength.resize(_capacity)
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_custom_data = true
	_mm.mesh = build_cone_mesh(tuning.traffic_cone_start_m, tuning.traffic_cone_length_m,
		tuning.traffic_cone_near_width_m, tuning.traffic_cone_far_width_m)
	_mm.instance_count = _capacity
	_mm.visible_instance_count = 0
	_mmi = MultiMeshInstance3D.new()
	_mmi.name = "Cones"
	_mmi.multimesh = _mm
	_mmi.material_override = MATERIAL
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_mmi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_mmi.visible = false
	add_child(_mmi)


## A flat trapezoid ahead of the origin (-Z): from `start_m` to `start_m + length_m`,
## `near_w` to `far_w` wide. UV = (side, along), UV2.x = the width at the vertex (see
## light_decal.gdshader SHAPE_CONE). Bounds grow for the instances' spread.
static func build_cone_mesh(start_m: float, length_m: float, near_w: float, far_w: float) -> ArrayMesh:
	var z0 := -start_m
	var z1 := -(start_m + length_m)
	var v := PackedVector3Array([Vector3(-near_w * 0.5, 0.0, z0), Vector3(near_w * 0.5, 0.0, z0),
		Vector3(-far_w * 0.5, 0.0, z1), Vector3(far_w * 0.5, 0.0, z1)])
	var uv := PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)])
	var uv2 := PackedVector2Array([Vector2(near_w, 0), Vector2(near_w, 0), Vector2(far_w, 0), Vector2(far_w, 0)])
	var normals := PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
	var idx := PackedInt32Array([0, 1, 2, 2, 1, 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
