class_name SkyRig
extends Node3D
## Sky dome, stars, cloud cards, horizon silhouettes, and the color-script push.
## Spec: World → Color script, Sky; Core loop → Sky timeline and sun clock;
## Performance budget. docs/CONTRACTS.md §13: this node is the only writer of
## the wb_* shader globals.
##
## Once per frame: sample the color script at `sky_t`, derive every global
## (colors converted sRGB -> linear, sun direction, fog distances from the
## quality view distance) and push only the ones that changed.
##
##   - Fog: fog_start/end = the key's fractions x Quality.view_distance_m, so the
##     fog end tracks the far plane (view distance + margin) on every tier and
##     through the governor; nothing is drawn fully inside the fog.
##   - Sun: azimuth fixed at world heading 0 (facing -Z, due west), elevation
##     from the color script. The road generator keeps it 15-30 deg off the camera
##     axis. No DirectionalLight3D is needed: world shaders light from wb_sun_dir.
##   - Sky meshes are unit directions placed around the camera by their shaders
##     (sky_common.gdshaderinc), so they follow the camera and ignore the
##     floating origin. The horizon's parallax field is sampled at absolute
##     positions via `origin`.
##   - Draw calls: dome, horizon (all layers), clouds = 3 by day; + stars at night.
##
## The world-system API (§13): setup(ctx, road, origin) and update_view(focus_s).
## The sun clock (WP3.5) or the dev slider sets `sky_t`.

## Emitted (at most once per frame) when the UI accent changes.
signal accent_changed(color: Color)

const GROUP := &"wb_sky"

## Every global this node writes; must equal project.godot [shader_globals].
const GLOBALS: Array[StringName] = [
	&"wb_sky_zenith", &"wb_sky_horizon", &"wb_sun_dir", &"wb_sun_disc_color",
	&"wb_sun_disc_size", &"wb_sun_glow", &"wb_stars",
	&"wb_cloud_lit", &"wb_cloud_shadow",
	&"wb_fog_color", &"wb_fog_start", &"wb_fog_end",
	&"wb_horizon_tint_0", &"wb_horizon_tint_1", &"wb_horizon_tint_2", &"wb_horizon_tint_3",
	&"wb_ambient", &"wb_sun_light_color", &"wb_sun_light_energy", &"wb_shadow_tint",
	&"wb_road_tone", &"wb_lane_line_tint",
	&"wb_emissive_headlight", &"wb_emissive_streetlamp", &"wb_emissive_reflector",
	&"wb_player_light_pos", &"wb_player_light_dir", &"wb_player_light_strength",
	&"wb_biome_tint_offset",
]

## World heading of the sun (docs/CONTRACTS.md §2: 0 faces -Z).
const SUN_HEADING_RAD := 0.0
## Below this star visibility the star mesh is hidden (saves its draw call).
const STARS_VISIBLE_MIN := 0.001  # lint: allow-number visibility epsilon, not tuning
## Number of horizon layers in the mesh and the shader.
const HORIZON_LAYERS := 4
## Clouds and stars are laid out from this stream (visual only).
const LAYOUT_STREAM := &"sky_layout"

@export var color_script: ColorScript
## Position on the sky timeline, cyclic [0, 1). See SunTuning.sky_t_*.
@export_range(0.0, 1.0, 0.001) var sky_t: float = 0.2
## > 0: use this view distance instead of the Quality autoload (previews, tests).
@export var view_distance_override_m: float = 0.0

@export_group("Layout")
@export var layout_seed: int = 7
@export var horizon_segments: int = 720
@export var star_count: int = 450
@export var cloud_count: int = 16
## Cloud elevation range and angular size range (degrees).
@export var cloud_elevation_deg: Vector2 = Vector2(4.0, 30.0)
@export var cloud_width_deg: Vector2 = Vector2(9.0, 24.0)
## Share of clouds placed within +-cloud_ahead_deg of due west (the view).
@export var cloud_ahead_share: float = 0.7
@export var cloud_ahead_deg: float = 75.0
## Columns per cloud card (facets along its top edge).
@export var cloud_columns: int = 9
## Card height / width range.
@export var cloud_aspect: Vector2 = Vector2(0.16, 0.3)
## Puffs along the top edge: count range, center spread, radius and height
## ranges (in half-widths / card heights).
@export var cloud_puffs: Vector2i = Vector2i(2, 4)
@export var cloud_puff_spread: float = 0.6
@export var cloud_puff_radius: Vector2 = Vector2(0.35, 0.6)
@export var cloud_puff_height: Vector2 = Vector2(0.5, 1.0)
## Stars only above this elevation (degrees).
@export var star_min_elevation_deg: float = 2.0

## Where pushes go: (name: StringName, value: Variant) -> void. Tests inject a fake.
var push_sink: Callable = Callable(RenderingServer, &"global_shader_parameter_set")
## Keyframe positions; defaults to Tuning.load_default().sun.
var sun_tuning: SunTuning
## Floating origin for the horizon's absolute sampling (optional).
var origin: FloatingOrigin

var _s: ColorKey = ColorKey.new()
var _pushed: Dictionary = {}
var _pushes: int = 0
var _accent: Color = Color.BLACK
var _biome_tint: Vector3 = Vector3.ZERO
var _player_light_pos: Vector3 = Vector3.ZERO
var _player_light_dir: Vector3 = Vector3.FORWARD
var _player_light_gain: float = 0.0
var _fallback_view_m: float = 0.0
var _origin_xz: Vector2 = Vector2.INF

@onready var _dome: MeshInstance3D = $Dome
@onready var _stars: MeshInstance3D = $Stars
@onready var _horizon: MeshInstance3D = $Horizon
@onready var _clouds: MeshInstance3D = $Clouds


func _ready() -> void:
	add_to_group(GROUP)
	if color_script == null:
		color_script = ColorScript.load_default()
	if sun_tuning == null:
		sun_tuning = Tuning.load_default().sun
	color_script.bind(sun_tuning)
	_build_meshes()
	push_now()


func _process(_delta: float) -> void:
	push_now()


# ---------------------------------------------------------------- World-system API

## docs/CONTRACTS.md §13. Binds the keyframes to the run's tuning.
func setup(ctx: RunContext, _road: RoadPath, origin_node: FloatingOrigin) -> void:
	sun_tuning = ctx.tuning.sun
	origin = origin_node
	if color_script != null:
		color_script.bind(sun_tuning)


## docs/CONTRACTS.md §13. The sky follows the camera in its shaders; nothing to do.
func update_view(_focus_s: float) -> void:
	pass


# ---------------------------------------------------------------- Public API

## The UI accent ("the sky's neon", sRGB) at the current sky_t.
func get_accent() -> Color:
	return _accent


## The values sampled this frame (read-only; sRGB colors as authored).
func current() -> ColorKey:
	return _s


## Biome tint offset added to world albedo (linear RGB). Biomes blend it.
func set_biome_tint_offset(offset: Vector3) -> void:
	_biome_tint = offset


## Player "fake light" (spec: Night lighting). `gain` scales the color script's
## headlight ramp; 0 turns it off. Position and direction are render-space.
func set_player_light(pos: Vector3, dir: Vector3, gain: float) -> void:
	_player_light_pos = pos
	_player_light_dir = dir
	_player_light_gain = gain


## Unit vector toward the sun at `elevation_rad`, azimuth at world heading 0.
static func sun_direction(elevation_rad: float) -> Vector3:
	var c := cos(elevation_rad)
	return Vector3(sin(SUN_HEADING_RAD) * c, sin(elevation_rad), -cos(SUN_HEADING_RAD) * c)


## View distance that sets the fog: override, else Quality, else the default tier.
func view_distance_m() -> float:
	if view_distance_override_m > 0.0:
		return view_distance_override_m
	if is_inside_tree():
		var q := get_node_or_null(^"/root/Quality")
		if q != null:
			var v: float = q.get(&"view_distance_m")
			if v > 0.0:
				return v
	if _fallback_view_m <= 0.0:
		var qt := Tuning.load_default().quality
		_fallback_view_m = qt.view_distance_m[maxi(qt.tier_index(qt.default_tier), 0)]
	return _fallback_view_m


## Sample, derive and push. Returns how many globals were pushed (0 when
## nothing changed since the last call).
func push_now() -> int:
	if color_script == null:
		return 0
	color_script.sample_into(sky_t, _s)
	_pushes = 0
	var view := view_distance_m()
	_put(&"wb_sky_zenith", _s.sky_zenith.srgb_to_linear())
	_put(&"wb_sky_horizon", _s.sky_horizon.srgb_to_linear())
	_put(&"wb_sun_dir", sun_direction(deg_to_rad(_s.sun_elevation_deg)))
	_put(&"wb_sun_disc_color", _s.sun_disc_color.srgb_to_linear())
	_put(&"wb_sun_disc_size", deg_to_rad(_s.sun_disc_size_deg))
	_put(&"wb_sun_glow", _s.sun_glow)
	_put(&"wb_stars", _s.stars)
	_put(&"wb_cloud_lit", _s.cloud_lit.srgb_to_linear())
	_put(&"wb_cloud_shadow", _s.cloud_shadow.srgb_to_linear())
	_put(&"wb_fog_color", _s.fog_color.srgb_to_linear())
	var fog_end := clampf(_s.fog_end_frac, 0.0, 1.0) * view
	_put(&"wb_fog_start", minf(_s.fog_start_frac * view, fog_end))
	_put(&"wb_fog_end", fog_end)
	_put(&"wb_horizon_tint_0", _s.horizon_tint_0.srgb_to_linear())
	_put(&"wb_horizon_tint_1", _s.horizon_tint_1.srgb_to_linear())
	_put(&"wb_horizon_tint_2", _s.horizon_tint_2.srgb_to_linear())
	_put(&"wb_horizon_tint_3", _s.horizon_tint_3.srgb_to_linear())
	_put(&"wb_ambient", _s.ambient.srgb_to_linear())
	_put(&"wb_sun_light_color", _s.sun_light_color.srgb_to_linear())
	_put(&"wb_sun_light_energy", _s.sun_light_energy)
	_put(&"wb_shadow_tint", _s.shadow_tint.srgb_to_linear())
	_put(&"wb_road_tone", _s.road_tone.srgb_to_linear())
	_put(&"wb_lane_line_tint", _s.lane_line_tint.srgb_to_linear())
	_put(&"wb_emissive_headlight", _s.emissive_headlight)
	_put(&"wb_emissive_streetlamp", _s.emissive_streetlamp)
	_put(&"wb_emissive_reflector", _s.emissive_reflector)
	_put(&"wb_player_light_pos", _player_light_pos)
	_put(&"wb_player_light_dir", _player_light_dir)
	_put(&"wb_player_light_strength", _player_light_gain * _s.emissive_headlight)
	_put(&"wb_biome_tint_offset", _biome_tint)

	if _s.ui_accent != _accent:
		_accent = _s.ui_accent
		accent_changed.emit(_accent)
	if _stars != null:
		_stars.visible = _s.stars > STARS_VISIBLE_MIN
	_update_origin()
	return _pushes


func _put(global_name: StringName, value: Variant) -> void:
	if _pushed.has(global_name) and _pushed[global_name] == value:
		return
	_pushed[global_name] = value
	push_sink.call(global_name, value)
	_pushes += 1


func _update_origin() -> void:
	if _horizon == null:
		return
	var o := Vector2.ZERO
	if origin != null:
		o = Vector2(origin.origin_x, origin.origin_z)
	if o != _origin_xz:
		_origin_xz = o
		(_horizon.material_override as ShaderMaterial).set_shader_parameter(&"origin_xz", o)


# ---------------------------------------------------------------- Meshes

func _build_meshes() -> void:
	var rng := Rng.new(layout_seed).derive(LAYOUT_STREAM)
	_horizon.mesh = build_horizon_mesh(horizon_segments, HORIZON_LAYERS)
	_stars.mesh = build_star_mesh(star_count, deg_to_rad(star_min_elevation_deg), rng.derive(&"stars"))
	_clouds.mesh = build_cloud_mesh(cloud_count, rng.derive(&"clouds"))
	for mi: MeshInstance3D in [_dome, _stars, _horizon, _clouds]:
		# The shaders move every vertex to the camera: never frustum-cull these.
		mi.extra_cull_margin = 16384.0  # lint: allow-number engine maximum cull margin
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Unit horizontal direction at world heading `heading` (0 = -Z, +PI/2 = +X).
static func heading_dir(heading: float, elevation: float = 0.0) -> Vector3:
	var c := cos(elevation)
	return Vector3(sin(heading) * c, sin(elevation), -cos(heading) * c)


## Ring strips, one per layer, farthest layer first (the sky draws without
## depth writes, so index order is paint order): VERTEX = unit horizontal
## direction, UV = (layer, 0 bottom / 1 top). The shader displaces the top edge.
static func build_horizon_mesh(segments: int, layers: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for layer in range(layers - 1, -1, -1):
		var base := verts.size()
		for i in segments + 1:
			var d := heading_dir(TAU * float(i) / float(segments))
			verts.append(d)
			uvs.append(Vector2(layer, 0.0))
			verts.append(d)
			uvs.append(Vector2(layer, 1.0))
		for i in segments:
			var b := base + i * 2
			idx.append_array([b, b + 1, b + 2, b + 2, b + 1, b + 3])
	return _commit(verts, uvs, PackedColorArray(), idx)


## Star quads: every corner at the star's direction, UV = corner (-1..1),
## COLOR.r = brightness (few bright, many faint), COLOR.g = twinkle phase.
static func build_star_mesh(count: int, min_elevation: float, rng: Rng) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	var corners: Array[Vector2] = [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]
	var min_y := sin(min_elevation)
	for i in count:
		# Uniform on the sphere cap above min_y.
		var y := rng.float_range(min_y, 1.0)
		var a := rng.float_range(0.0, TAU)
		var r := sqrt(maxf(1.0 - y * y, 0.0))
		var d := Vector3(cos(a) * r, y, sin(a) * r)
		var bright := rng.unit()
		var col := Color(bright * bright * bright * 0.8 + 0.2, rng.unit(), 0.0, 1.0)
		var base := verts.size()
		for c: Vector2 in corners:
			verts.append(d)
			uvs.append(c)
			cols.append(col)
		idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	return _commit(verts, uvs, cols, idx)


## Flat cloud cards: a flat bottom and a bumpy faceted top, facing the camera.
## UV.x = -1..1 across, UV.y = 0 bottom .. 1 top, COLOR.r = shade jitter.
func build_cloud_mesh(count: int, rng: Rng) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	var ahead := deg_to_rad(cloud_ahead_deg)
	for i in count:
		var heading := rng.float_range(-ahead, ahead) if rng.chance(cloud_ahead_share) \
				else rng.float_range(0.0, TAU)
		var u := rng.unit()
		var el := deg_to_rad(lerpf(cloud_elevation_deg.x, cloud_elevation_deg.y, u * u))
		var w := deg_to_rad(rng.float_range(cloud_width_deg.x, cloud_width_deg.y))
		var h := w * rng.float_range(cloud_aspect.x, cloud_aspect.y)
		var center := heading_dir(heading, el)
		var right := heading_dir(heading + PI * 0.5)
		var up := right.cross(center).normalized()
		# 2-4 puffs along the top edge.
		var puffs := rng.int_range(cloud_puffs.x, cloud_puffs.y)
		var pc := PackedFloat64Array()
		var pr := PackedFloat64Array()
		var ph := PackedFloat64Array()
		for p in puffs:
			pc.append(rng.float_range(-cloud_puff_spread, cloud_puff_spread))
			pr.append(rng.float_range(cloud_puff_radius.x, cloud_puff_radius.y))
			ph.append(rng.float_range(cloud_puff_height.x, cloud_puff_height.y))
		var shade := rng.unit()
		var base := verts.size()
		for c in cloud_columns + 1:
			var x := lerpf(-1.0, 1.0, float(c) / float(cloud_columns))
			var top := 0.0
			for p in puffs:
				var q := (x - pc[p]) / pr[p]
				if absf(q) < 1.0:
					top = maxf(top, sqrt(1.0 - q * q) * ph[p])
			var taper := 1.0 - x * x * x * x
			top = maxf(top * taper, 0.0)
			var bottom := center + right * (x * w * 0.5)
			verts.append(bottom)
			uvs.append(Vector2(x, 0.0))
			cols.append(Color(shade, 0.0, 0.0, 1.0))
			verts.append(bottom + up * (top * h))
			uvs.append(Vector2(x, top))
			cols.append(Color(shade, 0.0, 0.0, 1.0))
		for c in cloud_columns:
			var b := base + c * 2
			idx.append_array([b, b + 1, b + 2, b + 2, b + 1, b + 3])
	return _commit(verts, uvs, cols, idx)


static func _commit(verts: PackedVector3Array, uvs: PackedVector2Array,
		cols: PackedColorArray, idx: PackedInt32Array) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	if not cols.is_empty():
		arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
