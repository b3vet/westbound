class_name ColorScript
extends Resource
## The color script: keyframes along sky_t and their interpolation. Spec: World →
## Color script; Core loop → Sky timeline and sun clock. Saved as
## data/color_script.tres (editable in the inspector). docs/CONTRACTS.md §8, §13.
##
## Pure: no nodes, no rendering. SkyRig (src/sun/sky.gd) samples it once per frame
## and pushes the result as shader globals.
##
## Keyframe positions come from SunTuning.sky_t_<key> (bind()), never from this
## file, so the sun clock and the palette cannot drift apart. sky_t is cyclic:
## after the last keyframe (dawn) it interpolates toward the first one (morning)
## at position + 1.0.
##
## Interpolation is linear per channel between the two neighbouring keys, in the
## authored (sRGB) space for colors. `sample_into` allocates nothing.

## Keyframe names in timeline order. Every one must exist in `keys` and as
## SunTuning.sky_t_<name>.
const KEY_ORDER: Array[StringName] = [
	&"morning", &"afternoon", &"golden_hour", &"sunset", &"dusk", &"night", &"dawn",
]

## Every interpolated channel of a ColorKey, in inspector order.
const CHANNELS: Array[StringName] = [
	&"sun_elevation_deg",
	&"sky_zenith", &"sky_horizon", &"sun_disc_color", &"sun_disc_size_deg", &"sun_glow",
	&"stars", &"cloud_lit", &"cloud_shadow",
	&"fog_color", &"fog_start_frac", &"fog_end_frac",
	&"horizon_tint_0", &"horizon_tint_1", &"horizon_tint_2", &"horizon_tint_3",
	&"ambient", &"sun_light_color", &"sun_light_energy", &"shadow_tint",
	&"road_tone", &"lane_line_tint",
	&"emissive_headlight", &"emissive_streetlamp", &"emissive_reflector",
	&"ui_accent",
]

const DEFAULT_PATH := "res://data/color_script.tres"

@export var keys: Array[ColorKey] = []

## Keys sorted by position, and their positions (filled by bind()).
var _sorted: Array[ColorKey] = []
var _positions: PackedFloat64Array = PackedFloat64Array()
var _bound_to: SunTuning


static func load_default() -> ColorScript:
	return load(DEFAULT_PATH) as ColorScript


## Resolve keyframe positions from `sun` (SunTuning.sky_t_<key>). Call again
## after editing the tuning or the keys. Unknown keys are dropped (see validate()).
func bind(sun: SunTuning) -> void:
	_bound_to = sun
	_sorted.clear()
	_positions.clear()
	var pairs: Array = []
	for k: ColorKey in keys:
		if k == null or not _tuning_field(k.key) in sun:
			continue
		pairs.append([position_in(sun, k.key), k])
	pairs.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for p: Array in pairs:
		_positions.append(p[0])
		_sorted.append(p[1])


func is_bound() -> bool:
	return _bound_to != null and not _sorted.is_empty()


## Position of keyframe `key` on sky_t, straight from the tuning.
static func position_in(sun: SunTuning, key: StringName) -> float:
	return float(sun.get(_tuning_field(key)))


static func _tuning_field(key: StringName) -> StringName:
	return StringName("sky_t_" + String(key))


## Position of `key` in the bound tuning (NAN when unknown or unbound).
func position_of(key: StringName) -> float:
	for i in _sorted.size():
		if _sorted[i].key == key:
			return _positions[i]
	return NAN


## The keyframe resource named `key`, or null.
func get_key(key: StringName) -> ColorKey:
	for k: ColorKey in keys:
		if k != null and k.key == key:
			return k
	return null


## Interpolated values at `sky_t` (any real; wrapped into [0, 1)) written into
## `out`. Binds to the default SunTuning on first use if bind() was not called.
func sample_into(sky_t: float, out: ColorKey) -> void:
	if not is_bound():
		bind(Tuning.load_default().sun)
	var n := _sorted.size()
	if n == 0:
		return
	var t := fposmod(sky_t, 1.0)
	# Segment from key i (at p0) to the next key (at p1); after the last key the
	# segment wraps to the first key at its position + 1.0.
	var i := n - 1
	for j in n:
		if _positions[j] > t:
			i = j - 1
			break
	var p0: float
	if i < 0:
		i = n - 1
		p0 = _positions[i] - 1.0
	else:
		p0 = _positions[i]
	var a: ColorKey = _sorted[i]
	var b: ColorKey = _sorted[(i + 1) % n]
	var p1: float = _positions[(i + 1) % n]
	if p1 <= p0:
		p1 += 1.0
	var span := p1 - p0
	var f := 0.0 if span <= 0.0 else clampf((t - p0) / span, 0.0, 1.0)
	for c: StringName in CHANNELS:
		out.set(c, lerp(a.get(c), b.get(c), f))
	out.key = a.key if f < 0.5 else b.key


## Allocating convenience for tools and tests.
func sample(sky_t: float) -> ColorKey:
	var out := ColorKey.new()
	sample_into(sky_t, out)
	return out


## The UI accent at `sky_t` (allocates a ColorKey; per-frame users read
## SkyRig.get_accent() instead).
func accent_at(sky_t: float) -> Color:
	return sample(sky_t).ui_accent


## Name of the keyframe nearest to `sky_t` (cyclic distance), for dev UIs.
func nearest_key(sky_t: float) -> StringName:
	if not is_bound():
		bind(Tuning.load_default().sun)
	var best := &""
	var best_d := INF
	var t := fposmod(sky_t, 1.0)
	for i in _sorted.size():
		var d := absf(_positions[i] - t)
		d = minf(d, 1.0 - d)
		if d < best_d:
			best_d = d
			best = _sorted[i].key
	return best


## Problems with the data (empty = valid): missing or unknown or duplicate keys,
## unset channels, positions out of order against KEY_ORDER.
func validate(sun: SunTuning) -> PackedStringArray:
	var errors := PackedStringArray()
	var seen: Dictionary = {}
	for k: ColorKey in keys:
		if k == null:
			errors.append("null keyframe")
			continue
		if not KEY_ORDER.has(k.key):
			errors.append("unknown keyframe '%s'" % k.key)
		if seen.has(k.key):
			errors.append("duplicate keyframe '%s'" % k.key)
		seen[k.key] = true
		for c: StringName in CHANNELS:
			if not is_channel_set(k, c):
				errors.append("%s: channel %s is unset" % [k.key, c])
	var prev := -INF
	for name: StringName in KEY_ORDER:
		if not seen.has(name):
			errors.append("missing keyframe '%s'" % name)
		var p := position_in(sun, name)
		if p < 0.0 or p >= 1.0 or p <= prev:
			errors.append("SunTuning.sky_t_%s = %s is out of order or outside [0, 1)" % [name, p])
		prev = p
	return errors


static func is_channel_set(k: ColorKey, channel: StringName) -> bool:
	var v: Variant = k.get(channel)
	if v is Color:
		return (v as Color).a > 0.0
	if v is float:
		return not is_nan(v)
	return false
