class_name TrafficDebugView
extends Node3D
# lint: not-sim rendering adapter for the sandbox; it reads TrafficState and never feeds it back
## Stand-in traffic renderer for the traffic sandbox (spec: Traffic → Traffic sandbox
## (debug scene); Visuals → lights). Dev only: WP3.1's TrafficView replaces it (same
## entry points: setup / capture_tick / set_palette).
##
## One MultiMesh of unit boxes, one draw call for everything (debug_vehicle.gdshader):
## per vehicle a body (length x width x the type's height, colored by driver profile,
## or by the biome palette after set_palette) and four light bars: tail/brake (dark,
## red above brake_light_decel, bigger and brighter above the strong threshold), head
## (headlights, high-beam flash), and one blinker stripe along each side (blinking
## amber while signaling or moving, both for hazards). Blob shadows in a second
## MultiMesh. Both carriageways; the opposite one can be hidden.
##
## Interpolation: capture_tick() snapshots s, d, yaw once per physics frame, before
## that frame's sim ticks; _process lerps from the snapshot to the current state by
## the physics interpolation fraction (a reused slot is never lerped). Positions are
## rebuilt from road space every frame, so origin shifts need no handling.

## Per-profile body colors (sRGB), in TrafficRegistry.PROFILE_IDS order.
const PROFILE_COLORS: Array[Color] = [
	Color("#4f8fe0"),   # cruiser
	Color("#c9ced8"),   # commuter
	Color("#e8423a"),   # aggressive
	Color("#d9822b"),   # truck
	Color("#e8c53a"),   # bus
	Color("#58c2b4"),   # van
	Color("#c05ad6"),   # motorbike
	Color("#6cc86a"),   # hesitant
]
const OPPOSITE_COLOR := Color("#7a7f8c")
const TAIL_OFF := Color("#4a1210")
## Tail lights with the headlights on (night): lit, dimmer than the brake lights.
const TAIL_NIGHT := Color("#9a1e14")
const BRAKE_ON := Color("#ff2a1a")
const BRAKE_STRONG := Color("#ff8a70")
const HEAD_OFF := Color("#3a3c44")
const HEAD_ON := Color("#fff2c0")
const HIGH_BEAM := Color("#ffffff")
const BLINK_ON := Color("#ffae1a")
const BLINK_OFF := Color("#3a3024")
## Blinker frequency (Hz); on for the first half of each period.
const BLINK_HZ := 1.5
## Body ride height and light bar sizes (m, or fractions of the body).
const RIDE_M := 0.25
const LIGHT_DEPTH_M := 0.12
const LIGHT_HEIGHT_FRAC := 0.14
const STRONG_SCALE := 1.8
const LIGHT_WIDTH_FRAC := 0.86
const LIGHT_Y_FRAC := 0.62
const STRIPE_WIDTH_M := 0.14
const STRIPE_LENGTH_FRAC := 0.8
const STRIPE_Y_FRAC := 0.9
const PARTS := 5
const SHADER := preload("res://src/traffic/dev/debug_vehicle.gdshader")

## Draw the opposite carriageway.
var show_opposite: bool = true:
	set(value):
		show_opposite = value
		if _opp_shadows != null:
			_opp_shadows.visible = value
## Seconds, for the blinker phase (the sandbox passes sim time).
var blink_time: float = 0.0

var road: RoadPath
var origin: FloatingOrigin
var registry: TrafficRegistry
var state: TrafficState
var opposite: TrafficState

var _mm: MultiMesh
var _mmi: MultiMeshInstance3D
var _shadows: BlobShadowMulti
var _opp_shadows: BlobShadowMulti
var _palette := PackedColorArray()
var _smp := RoadSample.new()
var _heights := PackedFloat64Array()
# Snapshot per slot (player side, then opposite), for interpolation.
var _prev_s := PackedFloat64Array()
var _prev_d := PackedFloat64Array()
var _prev_id := PackedInt32Array()
var _cap: int = 0


## Same entry point as TrafficView (WP3.1). `opposite_state` may be null.
func setup(_ctx: RunContext, road_path: RoadPath, floating_origin: FloatingOrigin, reg: TrafficRegistry,
		traffic_state: TrafficState, opposite_state: TrafficState) -> void:
	road = road_path
	origin = floating_origin
	registry = reg
	state = traffic_state
	opposite = opposite_state
	_heights.resize(reg.types.size())
	for i in reg.types.size():
		_heights[i] = reg.types[i].height_m
	_cap = state.capacity + (opposite.capacity if opposite != null else 0)
	_prev_s.resize(_cap)
	_prev_d.resize(_cap)
	_prev_id.resize(_cap)
	_prev_id.fill(-1)
	if _mmi == null:
		_mmi = MultiMeshInstance3D.new()
		_mmi.name = "Boxes"
		_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_mmi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		# Instances span the whole active window: never cull the MultiMesh as a whole.
		_mmi.extra_cull_margin = 16384.0
		var mat := ShaderMaterial.new()
		mat.shader = SHADER
		_mmi.material_override = mat
		add_child(_mmi)
		_shadows = BlobShadowMulti.new()
		_shadows.name = "Shadows"
		_shadows.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		_shadows.extra_cull_margin = 16384.0
		add_child(_shadows)
		_opp_shadows = BlobShadowMulti.new()
		_opp_shadows.name = "OppositeShadows"
		_opp_shadows.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		_opp_shadows.extra_cull_margin = 16384.0
		add_child(_opp_shadows)
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_custom_data = true
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	_mm.mesh = box
	_mm.instance_count = _cap * PARTS
	_mm.visible_instance_count = 0
	_mmi.multimesh = _mm
	_shadows.setup(state.capacity)
	_opp_shadows.setup(opposite.capacity if opposite != null else 1)
	_opp_shadows.visible = show_opposite


## Biome traffic palette (sRGB): bodies use color_index into it instead of the
## profile colors. An empty palette goes back to profile colors.
func set_palette(colors: PackedColorArray) -> void:
	_palette = colors


## Snapshot for interpolation: call once per physics frame, before the sim ticks.
func capture_tick() -> void:
	if state == null:
		return
	_capture(state, 0)
	if opposite != null:
		_capture(opposite, state.capacity)


## Instances drawn last frame (tests).
func drawn_vehicle_count() -> int:
	return floori(float(_mm.visible_instance_count) / float(PARTS)) if _mm != null else 0


func _capture(st: TrafficState, base: int) -> void:
	for i in st.capacity:
		if st.active[i] == 1:
			_prev_s[base + i] = st.s[i]
			_prev_d[base + i] = st.d[i]
			_prev_id[base + i] = st.vehicle_id[i]
		else:
			_prev_id[base + i] = -1


func _process(_delta: float) -> void:
	if state == null or road == null:
		return
	var f := Engine.get_physics_interpolation_fraction()
	var n := _draw(state, 0, 0, f, false, _shadows)
	if opposite != null and show_opposite:
		n = _draw(opposite, state.capacity, n, f, true, _opp_shadows)
	_mm.visible_instance_count = n * PARTS


## Writes the instances of every live vehicle of `st`; returns the new vehicle count.
func _draw(st: TrafficState, base: int, n: int, frac: float, opp: bool, shadows: BlobShadowMulti) -> int:
	var ox := origin.origin_x if origin != null else 0.0
	var oy := origin.origin_y if origin != null else 0.0
	var oz := origin.origin_z if origin != null else 0.0
	var blink_on := fposmod(blink_time * BLINK_HZ, 1.0) < 0.5
	for i in st.capacity:
		if st.active[i] == 0:
			shadows.hide_instance(i)
			continue
		var s := st.s[i]
		var d := st.d[i]
		if _prev_id[base + i] == st.vehicle_id[i]:
			s = lerpf(_prev_s[base + i], s, frac)
			d = lerpf(_prev_d[base + i], d, frac)
		road.sample_into(s, _smp)
		var yaw := atan2(st.v_lat[i], maxf(st.v[i], 1.0))
		if opp:
			yaw = PI
		var up := _smp.up
		var right := _smp.right.rotated(up, -yaw)
		var back := (-_smp.tangent).rotated(up, -yaw)
		var vlen := st.length[i]
		var wid := st.width[i]
		var hgt := _heights[st.type_id[i]]
		var ground := _smp.local_point(d, ox, oy, oz)
		var f := st.flags[i]
		var k := n * PARTS
		# Body.
		var body_col := OPPOSITE_COLOR if opp else _body_color(st, i)
		_put(k, right * wid, up * hgt, back * vlen, ground + up * (RIDE_M + hgt * 0.5), body_col, 0.0)
		# Tail / brake bar.
		var lh := hgt * LIGHT_HEIGHT_FRAC
		var tail := TAIL_OFF
		var glow := 0.0
		if (f & TrafficState.FLAG_HEADLIGHTS) != 0:
			tail = TAIL_NIGHT
			glow = 1.0
		if (f & TrafficState.FLAG_BRAKE_STRONG) != 0:
			tail = BRAKE_STRONG
			glow = 1.0
			lh *= STRONG_SCALE
		elif (f & TrafficState.FLAG_BRAKE) != 0:
			tail = BRAKE_ON
			glow = 1.0
		var ly := RIDE_M + hgt * LIGHT_Y_FRAC
		_put(k + 1, right * (wid * LIGHT_WIDTH_FRAC), up * lh, back * LIGHT_DEPTH_M,
			ground + up * ly + back * (vlen * 0.5), tail, glow)
		# Head bar.
		var head := HEAD_OFF
		var hglow := 0.0
		if (f & TrafficState.FLAG_HIGH_BEAM) != 0:
			head = HIGH_BEAM
			hglow = 1.0
		elif (f & TrafficState.FLAG_HEADLIGHTS) != 0:
			head = HEAD_ON
			hglow = 1.0
		_put(k + 2, right * (wid * LIGHT_WIDTH_FRAC), up * (hgt * LIGHT_HEIGHT_FRAC), back * LIGHT_DEPTH_M,
			ground + up * ly - back * (vlen * 0.5), head, hglow)
		# Blinker stripes along each side near the roof (visible from above).
		var hazard := (f & TrafficState.FLAG_HAZARD) != 0
		var left_on := blink_on and (hazard or (f & TrafficState.FLAG_BLINKER_LEFT) != 0)
		var right_on := blink_on and (hazard or (f & TrafficState.FLAG_BLINKER_RIGHT) != 0)
		var sy := RIDE_M + hgt * STRIPE_Y_FRAC
		for side in 2:
			var sgn := -1.0 if side == 0 else 1.0
			var on := left_on if side == 0 else right_on
			_put(k + 3 + side, right * STRIPE_WIDTH_M, up * (hgt * LIGHT_HEIGHT_FRAC), back * (vlen * STRIPE_LENGTH_FRAC),
				ground + up * sy + right * (sgn * (wid * 0.5)), BLINK_ON if on else BLINK_OFF, 1.0 if on else 0.0)
		shadows.place(i, _smp, d, yaw, vlen, wid, origin)
		n += 1
	return n


func _body_color(st: TrafficState, i: int) -> Color:
	if not _palette.is_empty():
		return _palette[st.color_index[i] % _palette.size()]
	var p := st.profile_id[i]
	return PROFILE_COLORS[p] if p >= 0 and p < PROFILE_COLORS.size() else OPPOSITE_COLOR


func _put(k: int, x: Vector3, y: Vector3, z: Vector3, pos: Vector3, col: Color, glow: float) -> void:
	_mm.set_instance_transform(k, Transform3D(Basis(x, y, z), pos))
	_mm.set_instance_custom_data(k, Color(col.r, col.g, col.b, glow))
