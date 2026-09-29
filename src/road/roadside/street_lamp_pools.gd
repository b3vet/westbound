class_name StreetLampPools
extends Node3D
## Street-lamp light pools on the road (WP5.4). Spec: World → Night lighting ("Street
## lamps: emissive heads and light-pool decals on the road"); World → Road (roadside
## rhythm: light poles every 50 m); Performance budget (road decals, draw calls).
## docs/NIGHT.md.
##
##   pools.setup(ctx, road, origin)     # world-system API (CONTRACTS §13)
##   pools.sky = sky
##   pools.update_view(player_s)         # once per frame
##
## The median light poles (Roadside's light_pole RhythmLayer, one every
## RoadTuning.light_pole_spacing_m at s = k * spacing) carry twin heads that light both
## carriageways; their heads are emissive already (world.gdshader: emissive class 2
## follows wb_emissive_streetlamp). Here: one MultiMesh (1 draw call) of soft pools
## lying on the road under each head (d = +-NightTuning.pool_d_m), for the poles from
## pool_behind_m behind the player to pool_ahead_m ahead, additive, fogged and ramped
## by the color script's street-lamp ramp (assets/shaders/light_decal.gdshader,
## materials/lamp_pool.tres). Instances are rewritten only when the window of poles
## moves or the floating origin shifts. Hidden (no draw call) while the ramp is below
## NightTuning.visible_min_ramp. Allocation-free per frame.

const MATERIAL := preload("res://assets/shaders/materials/lamp_pool.tres")
## Pools per pole: one under each head.
const HEADS := 2

## Night numbers; defaults to Tuning.night when it exists, else NightTuning.load_default().
var tuning: NightTuning
## Reads the street-lamp ramp (SkyRig.current().emissive_streetlamp). Null = always off.
var sky: SkyRig
## The street-lamp ramp read last frame.
var ramp: float = 0.0

var _road: RoadPath
var _origin: FloatingOrigin
var _spacing: float = 1.0
var _mm: MultiMesh
var _mmi: MultiMeshInstance3D
var _capacity: int = 0
var _count: int = 0
var _smp := RoadSample.new()
## CPU copy of the instance transforms (the source of truth for tests and tools; a
## headless renderer keeps no MultiMesh data).
var _xf: Array[Transform3D] = []
# The window last written (pole indices) and the origin it was written at.
var _k0: int = 0
var _k1: int = -1
var _written_origin := Vector3.INF
var _rewrites: int = 0


func _init() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF


## World-system API (CONTRACTS §13). Builds the MultiMesh once; later calls rebind.
func setup(ctx: RunContext, road: RoadPath, origin: FloatingOrigin) -> void:
	_road = road
	_origin = origin
	if tuning == null:
		var t: Variant = ctx.tuning.get(&"night") if ctx != null and ctx.tuning != null else null
		tuning = t as NightTuning if t is NightTuning else NightTuning.load_default()
	_spacing = maxf(ctx.tuning.road.light_pole_spacing_m, 1.0)
	if _mmi == null:
		_build()
	_invalidate()


## World-system API: once per frame with the player's s.
func update_view(focus_s: float) -> void:
	ramp = sky.current().emissive_streetlamp if sky != null else 0.0
	var lit := _road != null and is_finite(ramp) and ramp >= tuning.visible_min_ramp
	if lit:
		var k0 := maxi(ceili((focus_s - tuning.pool_behind_m) / _spacing), 0)
		var k1 := floori((focus_s + tuning.pool_ahead_m) / _spacing)
		var generated := _road.length_generated()
		if is_finite(generated):
			k1 = mini(k1, floori(generated / _spacing))
		k1 = mini(k1, k0 + int(_capacity / float(HEADS)) - 1)
		var o := _origin_vec()
		if k0 != _k0 or k1 != _k1 or o != _written_origin:
			_write(k0, k1, o)
		lit = _count > 0
	if _mmi.visible != lit:
		_mmi.visible = lit


## Pools drawn (0 while hidden).
func count() -> int:
	return _count if _mmi.visible else 0


func capacity() -> int:
	return _capacity


## Draw calls this frame (0 or 1).
func draw_calls() -> int:
	return 1 if _mmi.visible and _count > 0 else 0


## Times the instances were rewritten (tests: only when the window moves).
func rewrites() -> int:
	return _rewrites


func pool_transform(i: int) -> Transform3D:
	return _xf[i]


func node() -> MultiMeshInstance3D:
	return _mmi


func multimesh() -> MultiMesh:
	return _mm


# ---------------------------------------------------------------- Internals

func _invalidate() -> void:
	_k0 = 0
	_k1 = -1
	_written_origin = Vector3.INF
	_count = 0
	if _mm != null:
		_mm.visible_instance_count = 0
		_mmi.visible = false


func _origin_vec() -> Vector3:
	if _origin == null:
		return Vector3.ZERO
	return Vector3(_origin.origin_x, _origin.origin_y, _origin.origin_z)


func _write(k0: int, k1: int, o: Vector3) -> void:
	_k0 = k0
	_k1 = k1
	_written_origin = o
	_rewrites += 1
	var n := 0
	var ox := 0.0
	var oy := 0.0
	var oz := 0.0
	if _origin != null:
		ox = _origin.origin_x
		oy = _origin.origin_y
		oz = _origin.origin_z
	var half_d := tuning.pool_d_m
	for k in range(k0, k1 + 1):
		_road.sample_into(float(k) * _spacing, _smp)
		var b := Basis(_smp.right * tuning.pool_width_m, _smp.up, -_smp.tangent * tuning.pool_length_m)
		var lift := _smp.up * tuning.pool_lift_m
		_xf[n] = Transform3D(b, _smp.local_point(half_d, ox, oy, oz) + lift)
		_xf[n + 1] = Transform3D(b, _smp.local_point(-half_d, ox, oy, oz) + lift)
		_mm.set_instance_transform(n, _xf[n])
		_mm.set_instance_transform(n + 1, _xf[n + 1])
		n += HEADS
	_count = n
	_mm.visible_instance_count = n


func _build() -> void:
	var poles := ceili((tuning.pool_ahead_m + tuning.pool_behind_m) / _spacing) + 1
	_capacity = poles * HEADS
	_xf.resize(_capacity)
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_custom_data = true
	_mm.mesh = build_pool_mesh()
	_mm.instance_count = _capacity
	for i in _capacity:
		_mm.set_instance_custom_data(i, Color(1.0, 0.0, 0.0, 0.0))
	_mm.visible_instance_count = 0
	_mmi = MultiMeshInstance3D.new()
	_mmi.name = "Pools"
	_mmi.multimesh = _mm
	_mmi.material_override = MATERIAL
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_mmi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_mmi.visible = false
	add_child(_mmi)


## A unit quad on the XZ plane centered on the origin (x across, -z along), UV 0..1.
## Instances scale it to the pool's size.
static func build_pool_mesh() -> ArrayMesh:
	var v := PackedVector3Array([Vector3(-0.5, 0.0, 0.5), Vector3(0.5, 0.0, 0.5), Vector3(-0.5, 0.0, -0.5),
		Vector3(0.5, 0.0, -0.5)])
	var uv := PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)])
	var normals := PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
	var idx := PackedInt32Array([0, 1, 2, 2, 1, 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
