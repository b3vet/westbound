class_name SpeedLines
extends MeshInstance3D
## Speed lines and wind streaks. Spec: Audio, haptics and game feel → Speed effects
## ("speed lines and wind-streak particles above 180 km/h"); Performance budget
## (particles clamped per tier; no large translucent full-screen layers); plan D16 (in
## the hood and cockpit cameras nothing covers the road: the streaks keep to the edges).
##
## One static mesh of FeelTuning.speed_lines_count thin quads, built once, drawn in
## screen space by assets/shaders/speed_lines.gdshader: 1 draw call above the
## threshold, hidden (0 draw calls) at or below it. Per frame update() sets two
## uniforms (intensity, travel); the streak count (quality clamp), the edge-only inner
## radius and the day/night look are uniforms too, set when they change. No per-frame
## allocation. Every number is in FeelTuning's "Speed effects" group.

const SHADER := preload("res://assets/shaders/speed_lines.gdshader")
## Drawn after every other transparent layer (CONTRACTS.md §13: above the sky's -97).
const RENDER_PRIORITY := 10
## Golden-ratio step: streak angles spread evenly around the screen without a pattern.
const ANGLE_STEP := 0.6180339887   # lint: allow-number golden ratio, a shape constant
## Visual-only random seed (any constant).
const VISUAL_SEED := 1893
## Culling box half-size (m): the quads are placed in clip space by the shader, so the
## box only has to meet the view frustum wherever the camera is.
const CULL_HALF_M := 1.0e5   # lint: allow-number culling bound, not a tuning value

var feel: FeelTuning
## 0..1 (0 = hidden) and the streaks' loop position (passes, integrated from speed).
var intensity: float = 0.0
var travel: float = 0.0
## Streaks drawn (count x particle scale) and whether they keep to the edges.
var visible_count: int = 0
var edge_only: bool = false

var _mat: ShaderMaterial
var _count: int = 0
var _min_mps: float = 0.0
var _full_mps: float = 0.0


func _init() -> void:
	name = "SpeedLines"
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	custom_aabb = AABB(-Vector3.ONE * CULL_HALF_M, Vector3.ONE * CULL_HALF_M * 2.0)
	visible = false


## Builds the streak mesh and the material (load time).
func setup(tuning: FeelTuning, particle_scale: float) -> void:
	feel = tuning
	_count = maxi(tuning.speed_lines_count, 0)
	_min_mps = Units.kmh_to_mps(tuning.speed_lines_min_kmh)
	_full_mps = maxf(Units.kmh_to_mps(tuning.speed_lines_full_kmh), _min_mps + 1.0)
	mesh = _build_mesh(_count)
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	_mat.render_priority = RENDER_PRIORITY
	_mat.set_shader_parameter(&"wind_every", tuning.speed_lines_wind_every)
	_mat.set_shader_parameter(&"outer", tuning.speed_lines_outer)
	_mat.set_shader_parameter(&"length_frac", tuning.speed_lines_length)
	_mat.set_shader_parameter(&"width_px", tuning.speed_lines_width_px)
	_mat.set_shader_parameter(&"depth_m", tuning.speed_lines_depth_m)
	_mat.set_shader_parameter(&"color", Vector3(tuning.speed_lines_color.r, tuning.speed_lines_color.g,
		tuning.speed_lines_color.b))
	_mat.set_shader_parameter(&"strength", tuning.speed_lines_strength)
	_mat.set_shader_parameter(&"night_gain", tuning.speed_lines_night_gain)
	material_override = _mat
	edge_only = false
	_mat.set_shader_parameter(&"inner", tuning.speed_lines_inner)
	set_particle_scale(particle_scale)
	intensity = 0.0
	visible = false


## Quality clamp: streaks drawn = count x `scale`.
func set_particle_scale(particle_scale: float) -> void:
	visible_count = clampi(roundi(float(_count) * particle_scale), 0, _count)
	if _mat != null:
		_mat.set_shader_parameter(&"visible_count", visible_count)


## Edge-only (hood, cockpit: D16): streaks start at speed_lines_inner_edge.
func set_edge_only(on: bool) -> void:
	if on == edge_only or _mat == null:
		return
	edge_only = on
	_mat.set_shader_parameter(&"inner", feel.speed_lines_inner_edge if on else feel.speed_lines_inner)


## The intensity for a forward speed (m/s) and boost: 0 at or below the threshold.
func intensity_for(speed_mps: float, boosting: bool) -> float:
	if speed_mps <= _min_mps:
		return 0.0
	var k := lerpf(feel.speed_lines_min_intensity, 1.0,
		clampf((speed_mps - _min_mps) / (_full_mps - _min_mps), 0.0, 1.0))
	if boosting:
		k += feel.speed_lines_boost_gain
	return clampf(k, 0.0, 1.0)


## Once per frame (`dt`: scaled frame time). Hidden below the threshold.
func update(dt: float, speed_mps: float, boosting: bool) -> void:
	if _mat == null:
		return
	var k := intensity_for(speed_mps, boosting)
	if k <= 0.0 or visible_count <= 0:
		if visible:
			visible = false
			intensity = 0.0
		return
	var t := clampf((speed_mps - _min_mps) / (_full_mps - _min_mps), 0.0, 1.0)
	travel = fposmod(travel + dt * lerpf(feel.speed_lines_rate_min_hz, feel.speed_lines_rate_max_hz, t), 1.0)
	intensity = k
	_mat.set_shader_parameter(&"intensity", k)
	_mat.set_shader_parameter(&"travel", travel)
	visible = true


## Hides the streaks now (a crash, a new run).
func hide_lines() -> void:
	visible = false
	intensity = 0.0


func _build_mesh(n: int) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = VISUAL_SEED
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var idx := PackedInt32Array()
	verts.resize(n * 4)
	uvs.resize(n * 4)
	uv2s.resize(n * 4)
	idx.resize(n * 6)
	for i in n:
		var angle := fposmod(float(i) * ANGLE_STEP + rng.randf_range(-0.5, 0.5) / float(maxi(n, 1)), 1.0)
		var phase := rng.randf()
		var jitter := rng.randf()
		var v := i * 4
		verts[v] = Vector3(0.0, -1.0, 0.0)
		verts[v + 1] = Vector3(1.0, -1.0, 0.0)
		verts[v + 2] = Vector3(1.0, 1.0, 0.0)
		verts[v + 3] = Vector3(0.0, 1.0, 0.0)
		for c in 4:
			uvs[v + c] = Vector2(angle, phase)
			uv2s[v + c] = Vector2(jitter, float(i))
		var k := i * 6
		idx[k] = v
		idx[k + 1] = v + 1
		idx[k + 2] = v + 2
		idx[k + 3] = v
		idx[k + 4] = v + 2
		idx[k + 5] = v + 3
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	if n > 0:
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return am
