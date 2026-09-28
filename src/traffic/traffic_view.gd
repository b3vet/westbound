class_name TrafficView
extends Node3D
# lint: not-sim Node adapter that renders TrafficState read-only; it simulates nothing
## Renders the traffic of one or two carriageways. Spec: Traffic → Visuals (lights,
## motion, rendering: pooled per model, shared materials, per-instance color);
## Performance budget (draw calls, blob shadows, glow sprites); Cameras → Glare rule;
## World → Night lighting. Contracts: docs/CONTRACTS.md §2 (road space → world),
## §5 (TrafficState readers interpolate between ticks), §13 (look, floating origin).
##
##   view.setup(ctx, road, origin, registry, sim.state, director.opposite.state)
##   view.set_palette(biome.traffic_palette)
##   # every 120 Hz tick, right after traffic_sim.step / director.step:
##   view.capture_tick()
##   # _process draws from the last two captures at the physics interpolation fraction.
##
## One MultiMesh per model (body, glass, wheels and every lamp group in one mesh; one
## draw call per model with any vehicle on screen), one MultiMesh of glow sprites and
## headlight pools for every vehicle, one BlobShadowMulti: about models + 2 draw calls.
## Paint comes from a palette uniform (the biome's traffic palette, or a model's fixed
## palette); lamps, wheel spin and body roll/pitch come from per-instance custom data
## (see assets/shaders/traffic.gdshader and TrafficLights).
##
## Allocation-free after setup(): capture_tick() and render() only write preallocated
## packed arrays and MultiMesh instances. World transforms are rebuilt every frame
## from road space (64-bit) with the floating origin, so origin shifts need nothing
## beyond a redraw.

const TRAFFIC_MATERIAL := preload("res://assets/shaders/materials/traffic.tres")
const GLOW_MATERIAL := preload("res://assets/shaders/materials/glow.tres")
## Paint slots [0, BIOME_SLOTS) hold the biome palette; model palettes follow.
const BIOME_SLOTS := 32
## Glow instances per vehicle: the front pair and the rear pair.
const GLOWS_PER_VEHICLE := 2
## Triangles per glow instance: two sprites and the headlight pool.
const GLOW_TRIS := 6
const SHADOW_TRIS := 2
## Paint for palette slots nobody filled (the style palette's "steel").
const FALLBACK_PAINT := Color(0.6, 0.63, 0.66)
## A lamp spacing below this counts as a single central lamp (motorbikes).
const SINGLE_LAMP_M := 0.01   # lint: allow-number geometric epsilon, not a tuning value
## Headroom around the glow mesh bounds for camera-facing sprites (m).
const GLOW_BOUNDS_MARGIN_M := 3.0
## Body motion and wheels advance at most this many ticks per rendered frame (the
## engine's max_physics_steps_per_frame), so a hitch never flings them.
const MAX_FRAME_TICKS := 8
const BLINK_LEFT_FLAGS := TrafficState.FLAG_BLINKER_LEFT | TrafficState.FLAG_HAZARD
const BLINK_RIGHT_FLAGS := TrafficState.FLAG_BLINKER_RIGHT | TrafficState.FLAG_HAZARD

## Vehicle drawing numbers; defaults to the run's `Tuning.traffic_view`.
var tuning: TrafficViewTuning
## Vehicles further than this from the camera are skipped (set by setup(); the run may
## update it when the quality tier's view distance changes).
var cull_distance_m: float = 0.0


class ModelPool:
	extends RefCounted
	var id: StringName
	var mesh: Mesh
	var node: MultiMeshInstance3D
	var mm: MultiMesh
	## Instances written this frame.
	var count: int = 0
	var tris: int = 0
	var wheel_radius_m: float = 1.0
	## (half spacing, height, z) of the front and rear lamp pairs.
	var glow_front := Vector3.ZERO
	var glow_rear := Vector3.ZERO
	## First paint slot of the model's own palette, or -1 for the biome palette.
	var palette_base: int = -1
	var palette_size: int = 0
	## One central lamp per pair (motorbikes): the glow shows the more important kind.
	var single_lamp: bool = false


class Carriageway:
	extends RefCounted
	var state: TrafficState
	## +1: the player's carriageway (travel toward +s); -1: the opposite one.
	var dir: float = 1.0
	var live: PackedByteArray
	var id: PackedInt32Array
	var model: PackedInt32Array
	var inv_wheel_r: PackedFloat64Array
	# Snapshots of the last two ticks (0 = previous, 1 = last).
	var s0: PackedFloat64Array
	var s1: PackedFloat64Array
	var d0: PackedFloat64Array
	var d1: PackedFloat64Array
	var v1: PackedFloat64Array
	var vl0: PackedFloat64Array
	var vl1: PackedFloat64Array
	# Visual state advanced per rendered frame.
	var roll: PackedFloat64Array
	var pitch: PackedFloat64Array
	var wheel: PackedFloat64Array
	var blink_mask: PackedInt32Array
	var blink_start: PackedFloat64Array

	func _init(st: TrafficState, direction: float) -> void:
		state = st
		dir = direction
		var n := st.capacity
		live.resize(n)
		id.resize(n)
		model.resize(n)
		inv_wheel_r.resize(n)
		s0.resize(n)
		s1.resize(n)
		d0.resize(n)
		d1.resize(n)
		v1.resize(n)
		vl0.resize(n)
		vl1.resize(n)
		roll.resize(n)
		pitch.resize(n)
		wheel.resize(n)
		blink_mask.resize(n)
		blink_start.resize(n)


var _road: RoadPath
var _origin: FloatingOrigin
var _registry: TrafficRegistry
var _sides: Array[Carriageway] = []
var _models: Array[ModelPool] = []
var _model_by_path: Dictionary = {}
var _type_models: Array[PackedInt32Array] = []
var _material: ShaderMaterial
var _palette := PackedColorArray()
## The palette as the shader gets it: plain vectors, so no renderer applies a color
## space conversion to array uniforms (Mobile did to a PackedColorArray).
var _palette_v4 := PackedVector4Array()
var _biome_count: int = 0
var _next_palette_slot: int = BIOME_SLOTS
var _glow: MultiMeshInstance3D
var _glow_mm: MultiMesh
var _shadows: BlobShadowMulti
var _shadow_mm: MultiMesh
var _smp := RoadSample.new()

var _tick: int = 0
var _dt: float = 0.0
var _fraction: float = 1.0
## Sim time of the last render (body motion and wheels advance by the difference).
var _last_render_t: float = 0.0
var _visible: int = 0
var _glow_count: int = 0
var _shadow_count: int = 0

# Tuning in SI (from `tuning` at setup).
var _motion_tau: float = 1.0
var _roll_k: float = 0.0
var _roll_max: float = 0.0
var _pitch_k: float = 0.0
var _pitch_max: float = 0.0
var _yaw_min_v: float = 0.0
var _yaw_max: float = 0.0
var _teleport: float = 0.0
var _blink_hz: float = 1.0
var _blink_duty: float = 0.5
var _cull_behind: float = 0.0
var _shadow_lift: float = 0.0
var _shadow_scale: float = 1.0
var _shadow_dist2: float = 0.0
var _behind_focus: float = 0.0
## Road-space pre-cull window from update_view() (off until it is called).
var _focus_s: float = 0.0
var _has_focus: bool = false

# Results of the last _place() / _finish() (scratch, allocation-free).
var _pos := Vector3.ZERO
var _xf := Transform3D.IDENTITY
var _yaw: float = 0.0
var _d: float = 0.0
var _custom := Color()
var _bits: int = 0


func _init() -> void:
	# Instances are placed at the interpolated tick in _process; never interpolate again.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF


## Binds the view to the player's carriageway `state` and, optionally, the visual-only
## `opposite` carriageway (d < 0, moving toward -s). Load time; allocates.
func setup(ctx: RunContext, road: RoadPath, origin: FloatingOrigin, registry: TrafficRegistry,
		state: TrafficState, opposite: TrafficState = null) -> void:
	_road = road
	_origin = origin
	_registry = registry
	if tuning == null:
		tuning = ctx.tuning.traffic_view if ctx.tuning.traffic_view != null else TrafficViewTuning.load_default()
	_dt = ctx.tuning.traffic.near_dt()
	_read_tuning()
	_free_nodes()
	_sides.clear()
	_sides.append(Carriageway.new(state, 1.0))
	if opposite != null:
		_sides.append(Carriageway.new(opposite, -1.0))
	var total := 0
	for sd in _sides:
		total += sd.state.capacity
	_material = TRAFFIC_MATERIAL.duplicate() as ShaderMaterial
	_palette.resize(TrafficLights.PALETTE_SLOTS)
	_palette.fill(FALLBACK_PAINT)
	_biome_count = 0
	_load_models(total)
	_push_palette()
	_glow_mm = MultiMesh.new()
	_glow_mm.transform_format = MultiMesh.TRANSFORM_3D
	_glow_mm.use_custom_data = true
	_glow_mm.mesh = _build_glow_mesh()
	_glow_mm.instance_count = total * GLOWS_PER_VEHICLE
	_glow_mm.visible_instance_count = 0
	_glow = _make_instance(&"Glow", _glow_mm, GLOW_MATERIAL)
	_shadows = BlobShadowMulti.new()
	_shadows.name = &"Shadows"
	add_child(_shadows)
	_shadows.setup(total)
	_shadow_mm = _shadows.multimesh
	# Instances are written directly (the view already has the vehicle basis); every
	# instance keeps full strength, so custom data is written once here.
	for i in total:
		_shadow_mm.set_instance_custom_data(i, Color(1.0, 0.0, 0.0, 0.0))
	_shadow_mm.visible_instance_count = 0
	_shadow_lift = _shadows.lift_m
	_shadow_scale = 1.0 + _shadows.margin_frac
	_tick = 0
	_last_render_t = 0.0
	cull_distance_m = _default_cull_distance(ctx)
	if not Events.origin_shifted.is_connected(_on_origin_shifted):
		Events.origin_shifted.connect(_on_origin_shifted)


## Biome traffic palette (sRGB): TrafficState.color_index -> color (wraps around).
## Models with a fixed palette (motorbikes, the coach livery) keep theirs.
func set_palette(colors: PackedColorArray) -> void:
	_biome_count = mini(colors.size(), BIOME_SLOTS)
	for i in BIOME_SLOTS:
		_palette[i] = colors[i] if i < _biome_count else FALLBACK_PAINT
	if _material != null:
		_push_palette()


## Uploads the palette (sRGB values; the shader linearizes) as plain vec4s.
func _push_palette() -> void:
	_palette_v4 = palette_vectors(_palette)
	_material.set_shader_parameter(&"palette", _palette_v4)


## Colors as plain vec4 values for a shader array uniform (no color conversion).
static func palette_vectors(colors: PackedColorArray) -> PackedVector4Array:
	var out := PackedVector4Array()
	out.resize(colors.size())
	for i in colors.size():
		var c := colors[i]
		out[i] = Vector4(c.r, c.g, c.b, c.a)
	return out


## World-system hook (CONTRACTS §13): the player's s. Enables a cheap road-space
## pre-cull: vehicles more than `cull_behind_focus_m` behind it (behind every camera
## mode) or beyond the cull distance ahead are skipped before any math.
func update_view(focus_s: float) -> void:
	_focus_s = focus_s
	_has_focus = true


## Snapshots every carriageway after a sim tick (120 Hz). Allocation-free.
func capture_tick() -> void:
	_tick += 1
	var t_start := float(_tick - 1) * _dt
	for sd in _sides:
		_capture(sd, t_start)


func _process(_delta: float) -> void:
	if not _sides.is_empty():
		render(Engine.get_physics_interpolation_fraction())


## Draws every live vehicle at `fraction` between the last two captured ticks
## (0 = the previous tick, 1 = the last one), and advances wheel spin and body motion
## by the sim time since the last render. Allocation-free.
func render(fraction: float) -> void:
	_fraction = clampf(fraction, 0.0, 1.0)
	var t := (float(maxi(_tick - 1, 0)) + _fraction) * _dt
	var dt_frame := clampf(t - _last_render_t, 0.0, _dt * MAX_FRAME_TICKS)
	_last_render_t = t
	var alpha := 1.0 - exp(-dt_frame / _motion_tau)
	var cam: Camera3D = get_viewport().get_camera_3d() if is_inside_tree() else null
	var cam_pos := Vector3.ZERO
	var cam_fwd := Vector3.ZERO
	if cam != null:
		cam_pos = cam.global_position
		cam_fwd = -cam.global_transform.basis.z
	var cull2 := cull_distance_m * cull_distance_m
	var s_min := _focus_s - _behind_focus if _has_focus else -INF
	var s_max := _focus_s + cull_distance_m if _has_focus and cull_distance_m > 0.0 else INF
	for m in _models:
		m.count = 0
	_glow_count = 0
	_shadow_count = 0
	_visible = 0
	var day_tail := tuning.glow_day_tail
	for sd in _sides:
		var st := sd.state
		for i in st.capacity:
			if sd.live[i] == 0 or st.active[i] == 0 or sd.s1[i] < s_min or sd.s1[i] > s_max:
				continue
			# Visual body motion (roll from lateral, pitch from longitudinal acceleration,
			# + roll leans left as CarVisual) and wheel spin at v / r.
			var a_lat := sd.dir * (sd.vl1[i] - sd.vl0[i]) / _dt
			var roll_t := clampf(a_lat * _roll_k, -_roll_max, _roll_max)
			var pitch_t := clampf(st.accel[i] * _pitch_k, -_pitch_max, _pitch_max)
			sd.roll[i] += (roll_t - sd.roll[i]) * alpha
			sd.pitch[i] += (pitch_t - sd.pitch[i]) * alpha
			sd.wheel[i] = fposmod(sd.wheel[i] + sd.v1[i] * dt_frame * sd.inv_wheel_r[i], TAU)
			_place(sd, i, _fraction)
			var shadow := true
			if cam != null:
				var to := _pos - cam_pos
				var dist2 := to.length_squared()
				if (cull2 > 0.0 and dist2 > cull2) or to.dot(cam_fwd) < -_cull_behind:
					continue
				shadow = dist2 < _shadow_dist2
			_finish(sd, i, t)
			var m := _models[sd.model[i]]
			m.mm.set_instance_transform(m.count, _xf)
			m.mm.set_instance_custom_data(m.count, _custom)
			m.count += 1
			_visible += 1
			# Blob shadow: the vehicle's footprint grown by the margin, on the road plane
			# (skipped far away, where it would be a few pixels).
			if shadow:
				var b := _xf.basis
				_shadow_mm.set_instance_transform(_shadow_count, Transform3D(
					Basis(b.x * (st.width[i] * _shadow_scale), b.y, b.z * (st.length[i] * _shadow_scale)),
					_pos + b.y * _shadow_lift))
				_shadow_count += 1
			# Glow pairs (TrafficLights.rear_kind / front_kind / glow_code, inlined): each
			# instance reuses the vehicle transform; lamp offsets go in the custom data.
			var bits := _bits
			if bits == 0 and not day_tail:
				continue
			var rear := TrafficLights.KIND_OFF
			if (bits & TrafficLights.BIT_BRAKE_STRONG) != 0:
				rear = TrafficLights.KIND_BRAKE_STRONG
			elif (bits & TrafficLights.BIT_BRAKE) != 0:
				rear = TrafficLights.KIND_BRAKE
			elif (bits & TrafficLights.BIT_HEAD) != 0 or day_tail:
				rear = TrafficLights.KIND_TAIL
			var front := TrafficLights.KIND_HEAD if (bits & TrafficLights.BIT_HEAD) != 0 else TrafficLights.KIND_OFF
			var bl := TrafficLights.KIND_BLINKER if (bits & TrafficLights.BIT_BLINK_L) != 0 else TrafficLights.KIND_OFF
			var br := TrafficLights.KIND_BLINKER if (bits & TrafficLights.BIT_BLINK_R) != 0 else TrafficLights.KIND_OFF
			var kl := maxi(bl, rear)
			var kr := maxi(br, rear)
			if kl != TrafficLights.KIND_OFF or kr != TrafficLights.KIND_OFF:
				var g := m.glow_rear
				if m.single_lamp:
					kl = maxi(kl, kr)
					kr = TrafficLights.KIND_OFF
				_glow_mm.set_instance_transform(_glow_count, _xf)
				_glow_mm.set_instance_custom_data(_glow_count,
					Color(float(kl + TrafficLights.GLOW_KIND_STRIDE * kr), g.x, g.y, g.z))
				_glow_count += 1
			kl = maxi(bl, front)
			kr = maxi(br, front)
			if kl != TrafficLights.KIND_OFF or kr != TrafficLights.KIND_OFF:
				var g := m.glow_front
				if m.single_lamp:
					kl = maxi(kl, kr)
					kr = TrafficLights.KIND_OFF
				_glow_mm.set_instance_transform(_glow_count, _xf)
				_glow_mm.set_instance_custom_data(_glow_count,
					Color(float(kl + TrafficLights.GLOW_KIND_STRIDE * kr + TrafficLights.GLOW_FRONT), g.x, g.y, g.z))
				_glow_count += 1
	for m in _models:
		if m.mm.visible_instance_count != m.count:
			m.mm.visible_instance_count = m.count
	if _glow_mm.visible_instance_count != _glow_count:
		_glow_mm.visible_instance_count = _glow_count
	if _shadow_mm.visible_instance_count != _shadow_count:
		_shadow_mm.visible_instance_count = _shadow_count


# ---------------------------------------------------------------- Budget numbers

## Draw calls the view submits this frame (models with a vehicle on screen, glow,
## shadows). Engine frustum culling can only lower it.
func draw_calls() -> int:
	var n := 0
	for m in _models:
		if m.count > 0:
			n += 1
	if _glow_count > 0:
		n += 1
	if _shadow_count > 0:
		n += 1
	return n


## Triangles submitted this frame (bodies, glow sprites and pools, shadows).
func triangles() -> int:
	var n := 0
	for m in _models:
		n += m.count * m.tris
	return n + _glow_count * GLOW_TRIS + _shadow_count * SHADOW_TRIS


## Vehicles drawn this frame (after culling).
func visible_count() -> int:
	return _visible


func glow_count() -> int:
	return _glow_count


func shadow_count() -> int:
	return _shadow_count


# ---------------------------------------------------------------- Inspection (tests, sandbox)

func model_count() -> int:
	return _models.size()


func model_id(index: int) -> StringName:
	return _models[index].id


func model_instances(index: int) -> int:
	return _models[index].mm.visible_instance_count


func model_capacity(index: int) -> int:
	return _models[index].mm.instance_count


func model_triangles(index: int) -> int:
	return _models[index].tris


## Model index a slot is drawn with (-1 if the slot is not live).
func slot_model(slot: int, opposite: bool = false) -> int:
	var sd := _side(opposite)
	return sd.model[slot] if sd != null and sd.live[slot] == 1 else -1


## The instance transform of a slot at `fraction` (< 0 = the last rendered fraction),
## computed exactly as render() does.
func slot_transform(slot: int, opposite: bool = false, fraction: float = -1.0) -> Transform3D:
	_inspect(slot, opposite, fraction)
	return _xf


## The instance custom data of a slot (wheel angle, roll, pitch, packed lamps + paint).
func slot_custom(slot: int, opposite: bool = false, fraction: float = -1.0) -> Color:
	_inspect(slot, opposite, fraction)
	return _custom


## Lamp bits (TrafficLights.BIT_*) of a slot at `fraction`.
func slot_bits(slot: int, opposite: bool = false, fraction: float = -1.0) -> int:
	_inspect(slot, opposite, fraction)
	return _bits


## Paint color (sRGB) a slot is drawn with.
func slot_paint(slot: int, opposite: bool = false) -> Color:
	_inspect(slot, opposite, -1.0)
	return _palette[TrafficLights.unpack_slot(_custom.a)]


## Sim time (s) of the last capture.
func captured_time() -> float:
	return float(_tick) * _dt


func _inspect(slot: int, opposite: bool, fraction: float) -> void:
	var sd := _side(opposite)
	var f := _fraction if fraction < 0.0 else clampf(fraction, 0.0, 1.0)
	var t := (float(maxi(_tick - 1, 0)) + f) * _dt
	if sd == null or sd.live[slot] == 0:
		_xf = Transform3D.IDENTITY
		_custom = Color()
		_bits = 0
		return
	_place(sd, slot, f)
	_finish(sd, slot, t)


func _side(opposite: bool) -> Carriageway:
	var k := 1 if opposite else 0
	return _sides[k] if k < _sides.size() else null


# ---------------------------------------------------------------- Capture

func _capture(sd: Carriageway, t_start: float) -> void:
	var st := sd.state
	for i in st.capacity:
		if st.active[i] == 0:
			sd.live[i] = 0
			continue
		var s := st.s[i]
		var fresh := sd.live[i] == 0 or sd.id[i] != st.vehicle_id[i]
		if fresh:
			var mi := _model_for(st.type_id[i], st.model_variant[i])
			if mi < 0:
				sd.live[i] = 0
				continue
			sd.live[i] = 1
			sd.id[i] = st.vehicle_id[i]
			sd.model[i] = mi
			sd.inv_wheel_r[i] = 1.0 / _models[mi].wheel_radius_m
			sd.roll[i] = 0.0
			sd.pitch[i] = 0.0
			sd.wheel[i] = 0.0
			sd.blink_mask[i] = 0
		if fresh or absf(s - sd.s1[i]) > _teleport:
			# New vehicle or a jump (recycle, reposition): no interpolation across it.
			sd.s0[i] = s
			sd.d0[i] = st.d[i]
			sd.vl0[i] = st.v_lat[i]
		else:
			sd.s0[i] = sd.s1[i]
			sd.d0[i] = sd.d1[i]
			sd.vl0[i] = sd.vl1[i]
		sd.s1[i] = s
		sd.d1[i] = st.d[i]
		sd.v1[i] = st.v[i]
		sd.vl1[i] = st.v_lat[i]
		# Blinkers (TrafficLights.blink_mask, inlined): a change of the flashing sides
		# restarts the cycle lit.
		var f := st.flags[i]
		var mask := 0
		if (f & BLINK_LEFT_FLAGS) != 0:
			mask = TrafficLights.MASK_L
		if (f & BLINK_RIGHT_FLAGS) != 0:
			mask |= TrafficLights.MASK_R
		if mask != sd.blink_mask[i]:
			sd.blink_mask[i] = mask
			sd.blink_start[i] = t_start


## Position of slot i at fraction f: fills _smp (road at the interpolated s), _d, _yaw
## and _pos (render space).
func _place(sd: Carriageway, i: int, f: float) -> void:
	var s := lerpf(sd.s0[i], sd.s1[i], f)
	_d = lerpf(sd.d0[i], sd.d1[i], f)
	var vl := lerpf(sd.vl0[i], sd.vl1[i], f)
	_road.sample_into(s, _smp)
	# Heading: the road's, plus the lane-change yaw atan2(v_lat, v) in the vehicle's own
	# frame (speed floored, clamped), plus a half turn on the opposite carriageway.
	var dev := clampf(atan2(sd.dir * vl, maxf(sd.v1[i], _yaw_min_v)), -_yaw_max, _yaw_max)
	_yaw = dev if sd.dir > 0.0 else PI + dev
	if _origin != null:
		_pos = _smp.local_point(_d, _origin.origin_x, _origin.origin_y, _origin.origin_z)
	else:
		_pos = _smp.local_point(_d, 0.0, 0.0, 0.0)


## Basis, lamp bits and custom data of slot i at sim time t (after _place).
func _finish(sd: Carriageway, i: int, t: float) -> void:
	var up := _smp.up
	_xf = Transform3D(Basis(_smp.right.rotated(up, -_yaw), up, (-_smp.tangent).rotated(up, -_yaw)), _pos)
	# Lamp bits (TrafficLights.bits, inlined). FLAG_HIGH_BEAM is ignored (decision D8).
	var st := sd.state
	var flags := st.flags[i]
	var b := 0
	if (flags & TrafficState.FLAG_BRAKE) != 0:
		b = TrafficLights.BIT_BRAKE
	if (flags & TrafficState.FLAG_BRAKE_STRONG) != 0:
		b = TrafficLights.BIT_BRAKE | TrafficLights.BIT_BRAKE_STRONG
	if (flags & TrafficState.FLAG_HEADLIGHTS) != 0:
		b |= TrafficLights.BIT_HEAD
	var mask := sd.blink_mask[i]
	if mask != 0:
		var elapsed := t - sd.blink_start[i]
		if elapsed >= 0.0 and fposmod(elapsed * _blink_hz, 1.0) < _blink_duty:
			if (mask & TrafficLights.MASK_L) != 0:
				b |= TrafficLights.BIT_BLINK_L
			if (mask & TrafficLights.MASK_R) != 0:
				b |= TrafficLights.BIT_BLINK_R
	_bits = b
	var m := _models[sd.model[i]]
	var paint := 0
	if m.palette_base >= 0:
		paint = m.palette_base + posmod(st.color_index[i], m.palette_size)
	elif _biome_count > 0:
		paint = posmod(st.color_index[i], _biome_count)
	_custom = Color(sd.wheel[i], sd.roll[i], sd.pitch[i], float(b + TrafficLights.PALETTE_STRIDE * paint))


func _on_origin_shifted(_offset: Vector3) -> void:
	# Transforms come from 64-bit road space and the new origin: redraw at once so no
	# frame shows the old origin.
	if not _sides.is_empty():
		render(_fraction)


# ---------------------------------------------------------------- Setup helpers

func _read_tuning() -> void:
	_motion_tau = maxf(tuning.body_motion_time_constant_s, _dt)
	_roll_max = deg_to_rad(tuning.body_roll_max_deg)
	_roll_k = _roll_max / tuning.body_roll_full_accel_mps2
	_pitch_max = deg_to_rad(tuning.body_pitch_max_deg)
	_pitch_k = _pitch_max / tuning.body_pitch_full_accel_mps2
	_yaw_min_v = tuning.yaw_min_speed_mps()
	_yaw_max = deg_to_rad(tuning.yaw_max_deg)
	_teleport = tuning.teleport_distance_m
	_blink_hz = tuning.blinker_hz
	_blink_duty = tuning.blinker_duty_frac()
	_cull_behind = tuning.cull_behind_m
	_behind_focus = tuning.cull_behind_focus_m
	_shadow_dist2 = tuning.shadow_distance_m * tuning.shadow_distance_m


func _default_cull_distance(ctx: RunContext) -> float:
	if tuning.cull_distance_m > 0.0:
		return tuning.cull_distance_m
	var q := get_node_or_null(^"/root/Quality") if is_inside_tree() else null
	if q != null and float(q.get(&"view_distance_m")) > 0.0:
		return float(q.get(&"view_distance_m"))
	var qt := ctx.tuning.quality
	var tier := maxi(qt.tier_index(qt.default_tier), 0)
	return qt.view_distance_m[tier] + qt.far_plane_margin_m


func _load_models(instance_capacity: int) -> void:
	_models.clear()
	_model_by_path.clear()
	_type_models.clear()
	_next_palette_slot = BIOME_SLOTS
	for t in _registry.types:
		var ids := PackedInt32Array()
		for path in t.model_scene_paths:
			var k := _load_model(path, instance_capacity)
			if k >= 0:
				ids.append(k)
		if ids.is_empty():
			push_warning("TrafficView: vehicle type %s has no model; its vehicles are not drawn" % t.id)
		_type_models.append(ids)


func _load_model(path: String, instance_capacity: int) -> int:
	if _model_by_path.has(path):
		return _model_by_path[path]
	var mesh := load_model_mesh(path)
	if mesh == null:
		push_error("TrafficView: cannot load a model mesh from %s" % path)
		return -1
	var m := ModelPool.new()
	m.id = StringName(path.get_file().get_basename())
	m.mesh = mesh
	m.tris = mesh_triangles(mesh)
	var bounds := mesh.get_aabb()
	m.wheel_radius_m = float(mesh.get_meta(&"wheel_radius_m", bounds.size.y * 0.5 * 0.5))
	var hs := bounds.size.x * 0.5 * 0.5
	m.glow_front = mesh.get_meta(&"glow_front", Vector3(hs, bounds.size.y * 0.5, bounds.position.z))
	m.glow_rear = mesh.get_meta(&"glow_rear", Vector3(hs, bounds.size.y * 0.5, bounds.end.z))
	m.single_lamp = m.glow_front.x < SINGLE_LAMP_M and m.glow_rear.x < SINGLE_LAMP_M
	var pal: PackedColorArray = mesh.get_meta(&"paint_palette", PackedColorArray())
	if not pal.is_empty():
		var n := mini(pal.size(), TrafficLights.PALETTE_SLOTS - _next_palette_slot)
		if n > 0:
			m.palette_base = _next_palette_slot
			m.palette_size = n
			for i in n:
				_palette[_next_palette_slot + i] = pal[i]
			_next_palette_slot += n
		else:
			push_warning("TrafficView: no paint slots left for %s's palette" % m.id)
	m.mm = MultiMesh.new()
	m.mm.transform_format = MultiMesh.TRANSFORM_3D
	m.mm.use_custom_data = true
	# Compatibility multiplies the vertex COLOR by the instance color even when the
	# MultiMesh has none (it reads zero): carry white instance colors, written once.
	m.mm.use_colors = true
	m.mm.mesh = mesh
	m.mm.instance_count = instance_capacity
	for i in instance_capacity:
		m.mm.set_instance_color(i, Color.WHITE)
	m.mm.visible_instance_count = 0
	m.node = _make_instance(StringName("Model_" + String(m.id)), m.mm, _material)
	_models.append(m)
	var k := _models.size() - 1
	_model_by_path[path] = k
	return k


func _model_for(type_id: int, variant: int) -> int:
	if type_id < 0 or type_id >= _type_models.size():
		return -1
	var ids := _type_models[type_id]
	if ids.is_empty():
		return -1
	return ids[posmod(variant, ids.size())]


func _make_instance(node_name: StringName, mm: MultiMesh, mat: Material) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(mmi)
	return mmi


func _free_nodes() -> void:
	for m in _models:
		if is_instance_valid(m.node):
			m.node.free()
	_models.clear()
	if is_instance_valid(_glow):
		_glow.free()
	if is_instance_valid(_shadows):
		_shadows.free()


## Glow mesh: two camera-facing lamp quads (VERTEX.x = -1 / +1, UV = corner) and the
## headlight pool on the road ahead of the lamps (UV2.x = 1; VERTEX.x across, VERTEX.z
## ahead, negative). See glow.gdshader. Instances use the vehicle transform, so the
## bounds cover the largest model plus its pool.
func _build_glow_mesh() -> ArrayMesh:
	var v := PackedVector3Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var corners := PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 0), Vector2(1, 1),
		Vector2(0, 1)])
	for side: float in [-1.0, 1.0]:
		for c in corners:
			v.append(Vector3(side, 0.0, 0.0))
			uv.append(c)
			uv2.append(Vector2.ZERO)
	var z0 := -tuning.pool_start_m
	var z1 := -(tuning.pool_start_m + tuning.pool_length_m)
	var wn := tuning.pool_near_width_m * 0.5
	var wf := tuning.pool_far_width_m * 0.5
	var pool := PackedVector3Array([Vector3(-wn, 0.0, z0), Vector3(wn, 0.0, z0), Vector3(wf, 0.0, z1),
		Vector3(-wn, 0.0, z0), Vector3(wf, 0.0, z1), Vector3(-wf, 0.0, z1)])
	var pool_uv := PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 0), Vector2(1, 1),
		Vector2(0, 1)])
	for k in pool.size():
		v.append(pool[k])
		uv.append(pool_uv[k])
		uv2.append(Vector2(1.0, 0.0))
	var normals := PackedVector3Array()
	normals.resize(v.size())
	normals.fill(Vector3.UP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# Sprites grow in the shader; the pool reaches pool_length_m ahead of the front lamps.
	var model_bounds := AABB()
	for m in _models:
		model_bounds = model_bounds.merge(m.mesh.get_aabb())
	var r := maxf(wf, model_bounds.size.x * 0.5) + GLOW_BOUNDS_MARGIN_M
	var ahead := -model_bounds.position.z + tuning.pool_start_m + tuning.pool_length_m + GLOW_BOUNDS_MARGIN_M
	var behind := model_bounds.end.z + GLOW_BOUNDS_MARGIN_M
	var top := model_bounds.end.y + GLOW_BOUNDS_MARGIN_M
	mesh.custom_aabb = AABB(Vector3(-r, -GLOW_BOUNDS_MARGIN_M, -ahead), Vector3(2.0 * r, top + GLOW_BOUNDS_MARGIN_M,
		ahead + behind))
	return mesh


# ---------------------------------------------------------------- Model files

## The mesh of a traffic model: a Mesh resource, or a scene whose "Body"
## MeshInstance3D holds it (the traffic version of the modular car convention).
static func load_model_mesh(path: String) -> Mesh:
	if not ResourceLoader.exists(path):
		return null
	var res := load(path)
	if res is Mesh:
		return res as Mesh
	if res is PackedScene:
		var inst := (res as PackedScene).instantiate()
		var body := inst.get_node_or_null(^"Body") as MeshInstance3D
		var mesh: Mesh = body.mesh if body != null else null
		inst.free()
		return mesh
	return null


static func mesh_triangles(mesh: Mesh) -> int:
	var n := 0
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var corners := idx.size() if not idx.is_empty() else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		n += floori(float(corners) / 3.0)
	return n
