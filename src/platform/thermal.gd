class_name Thermal
extends RefCounted
## Device thermal state. Spec: Tech stack → Platform services ("A small native plugin per
## platform reports thermal state (iOS ProcessInfo.thermalState, Android
## PowerManager.getCurrentThermalStatus) to the governor"); Performance budget → Adaptive
## governor; Implementation milestones → M9 ("the governor steps down and up correctly
## under a forced thermal state"). WP9.1, docs/QUALITY.md → Thermal.
##
## Where the state comes from, first that applies:
##   1. A dev override: `?thermal=<script>` on the web or `--thermal=<script>` on the
##      command line (Quality reads it at boot), or force() / force_script() (the dev HUD's
##      THERMAL button, tests). A script is `state[:seconds],state[:seconds],...`: each
##      state lasts its seconds (of frames advance()d), the last one holds. `serious` alone
##      forces serious; `serious:45,nominal` is the M9 gate check (down, then back up).
##   2. The native plugin singleton `WestboundThermal` (sources in platform/ios/thermal and
##      platform/android/thermal; UNTESTED ON DEVICE), read on its signal and polled every
##      thermal_poll_s.
##   3. Nothing (web, desktop, a build without the plugin): nominal, available() false. The
##      governor then works from frame times alone.
##
## Plugin interface (the same on both platforms):
##   get_raw_state() -> int      the platform's own value (iOS ProcessInfo.ThermalState
##                               0..3; Android PowerManager THERMAL_STATUS_* 0..6), -1 unknown
##   get_platform() -> String    "ios" or "android"
##   is_supported() -> bool      false where the OS has no thermal API (Android < 10)
##   signal thermal_state_changed(raw_state: int)   (main thread; optional, polling covers it)
## Raw values become levels through QualityTuning.thermal_ios_levels / thermal_android_levels
## (0 nominal, 1 fair, 2 serious, 3 critical); unknown values read nominal.

## The level changed (Quality forwards it to Events.thermal_state_changed).
signal changed(state: StringName)

const NOMINAL := &"nominal"
const FAIR := &"fair"
const SERIOUS := &"serious"
const CRITICAL := &"critical"
## Index = level.
const STATES: Array[StringName] = [NOMINAL, FAIR, SERIOUS, CRITICAL]

const SINGLETON := "WestboundThermal"
const SIGNAL_NATIVE := &"thermal_state_changed"
const PLATFORM_IOS := &"ios"
const PLATFORM_ANDROID := &"android"
## The boot parameter (`?thermal=` / `--thermal=`).
const BOOT_PARAM := "thermal"
const SOURCE_NONE := &"none"
const SOURCE_NATIVE := &"native"
const SOURCE_FORCED := &"forced"
## Longest forced script (entries).
const SCRIPT_CAPACITY := 16

var poll_s: float = 0.0
var ios_levels := PackedInt32Array()
var android_levels := PackedInt32Array()

var _native: Object
var _platform: StringName = &""
var _raw: int = -1
var _level: int = 0
var _poll_t: float = 0.0
var _forced: bool = false
var _script_levels := PackedInt32Array()
var _script_secs := PackedFloat64Array()
var _script_i: int = 0
var _script_t: float = 0.0


func _init() -> void:
	configure(null)


## Poll interval and raw-state maps from a QualityTuning (null or a double: the defaults).
func configure(t: Resource) -> void:
	var d := QualityTuning.new()
	var src: Resource = t if t != null else d
	poll_s = float(src.get(&"thermal_poll_s")) if &"thermal_poll_s" in src else d.thermal_poll_s
	ios_levels = src.get(&"thermal_ios_levels") if &"thermal_ios_levels" in src else d.thermal_ios_levels
	android_levels = src.get(&"thermal_android_levels") if &"thermal_android_levels" in src \
		else d.thermal_android_levels


# ---------------------------------------------------------------- State

## One of NOMINAL, FAIR, SERIOUS, CRITICAL.
func get_state() -> StringName:
	return STATES[_level]


## 0 nominal .. 3 critical.
func level() -> int:
	return _level


## SOURCE_FORCED, SOURCE_NATIVE or SOURCE_NONE.
func source() -> StringName:
	if _forced:
		return SOURCE_FORCED
	return SOURCE_NATIVE if _native != null else SOURCE_NONE


## A thermal reading exists (a native plugin or a dev override).
func available() -> bool:
	return _forced or _native != null


func is_forced() -> bool:
	return _forced


## The native plugin's last raw value (-1: none or unknown).
func raw_state() -> int:
	return _raw


func platform() -> StringName:
	return _platform


static func level_of(state: StringName) -> int:
	return maxi(STATES.find(state), 0)


## A platform's raw value → level through its map (unknown or negative: nominal).
static func map_raw(raw: int, levels: PackedInt32Array) -> int:
	if raw < 0 or levels.is_empty():
		return 0
	var i := mini(raw, levels.size() - 1)
	return clampi(levels[i], 0, STATES.size() - 1)


# ---------------------------------------------------------------- Native plugin

## Attaches the `WestboundThermal` singleton when the build has it (iOS / Android with the
## plugin enabled). True when attached.
func detect() -> bool:
	if not Engine.has_singleton(SINGLETON):
		return false
	return attach_native(Engine.get_singleton(SINGLETON))


## Uses `plugin` (the singleton, or a test double with the same interface) as the source.
func attach_native(plugin: Object) -> bool:
	detach_native()
	if plugin == null:
		return false
	if plugin.has_method(&"is_supported") and not bool(plugin.call(&"is_supported")):
		return false
	_native = plugin
	var p := String(plugin.call(&"get_platform")) if plugin.has_method(&"get_platform") else ""
	if p.is_empty():
		p = String(PLATFORM_IOS) if OS.has_feature("ios") else String(PLATFORM_ANDROID)
	_platform = StringName(p)
	if plugin.has_signal(SIGNAL_NATIVE):
		plugin.connect(SIGNAL_NATIVE, _on_native_changed)
	_poll_t = 0.0
	poll()
	return true


func detach_native() -> void:
	if _native != null and is_instance_valid(_native) and _native.has_signal(SIGNAL_NATIVE) \
			and _native.is_connected(SIGNAL_NATIVE, _on_native_changed):
		_native.disconnect(SIGNAL_NATIVE, _on_native_changed)
	_native = null
	_raw = -1
	if not _forced:
		_set_level(0)


## Reads the plugin now.
func poll() -> void:
	if _native == null or not is_instance_valid(_native):
		return
	if _native.has_method(&"get_raw_state"):
		_on_native_changed(int(_native.call(&"get_raw_state")))


func _on_native_changed(raw: int) -> void:
	_raw = raw
	if not _forced:
		_set_level(map_raw(raw, levels_for(_platform)))


func levels_for(p: StringName) -> PackedInt32Array:
	return ios_levels if p == PLATFORM_IOS else android_levels


# ---------------------------------------------------------------- Dev override

## Forces `state` until clear_force().
func force(state: StringName) -> void:
	_script_levels.resize(1)
	_script_secs.resize(1)
	_script_levels[0] = level_of(state)
	_script_secs[0] = 0.0
	_start_script()


## Forces a timeline: levels[i] for secs[i] seconds each (the last one holds).
func force_script(levels: PackedInt32Array, secs: PackedFloat64Array) -> void:
	if levels.is_empty():
		clear_force()
		return
	_script_levels = levels.duplicate()
	_script_secs = secs.duplicate()
	_script_secs.resize(levels.size())
	_start_script()


## Back to the native plugin (or nominal).
func clear_force() -> void:
	_forced = false
	_script_levels.clear()
	_script_secs.clear()
	if _native != null:
		poll()
	else:
		_set_level(0)


## A boot override (`serious`, `serious:45,nominal`, `off`). False (and a warning) when it
## does not parse; nothing changes then.
func apply_override(text: String) -> bool:
	var t := text.strip_edges().to_lower()
	if t.is_empty() or t == "off" or t == "auto":
		clear_force()
		return not t.is_empty()
	var levels := PackedInt32Array()
	var secs := PackedFloat64Array()
	if not parse_script(t, levels, secs):
		push_warning("Thermal: ignoring override '%s' (want state[:seconds],... with states %s)" % [
			text, ", ".join(PackedStringArray(STATES))])
		return false
	force_script(levels, secs)
	return true


## Parses `state[:seconds],...` into `levels` / `secs` (appended). False on an unknown
## state, a bad or negative duration, or more than SCRIPT_CAPACITY entries.
static func parse_script(text: String, levels: PackedInt32Array, secs: PackedFloat64Array) -> bool:
	var parts := text.split(",", false)
	if parts.is_empty() or parts.size() > SCRIPT_CAPACITY:
		return false
	for part in parts:
		var kv := part.strip_edges().split(":")
		if kv.size() > 2:
			return false
		var i := STATES.find(StringName(kv[0].strip_edges()))
		if i < 0:
			return false
		var s := 0.0
		if kv.size() == 2:
			if not kv[1].strip_edges().is_valid_float():
				return false
			s = kv[1].strip_edges().to_float()
			if s < 0.0:
				return false
		levels.append(i)
		secs.append(s)
	return true


## Dev HUD: not forced → nominal → fair → serious → critical → not forced.
func cycle_force() -> void:
	if not _forced:
		force(NOMINAL)
	elif _level + 1 < STATES.size() and _script_levels.size() == 1:
		force(STATES[_level + 1])
	else:
		clear_force()


# ---------------------------------------------------------------- Time

## One frame of `dt` real seconds: the forced timeline, or the plugin poll.
func advance(dt: float) -> void:
	if _forced:
		_advance_script(dt)
		return
	if _native == null:
		return
	_poll_t += dt
	if poll_s > 0.0 and _poll_t >= poll_s:
		_poll_t = 0.0
		poll()


func _start_script() -> void:
	_forced = true
	_script_i = 0
	_script_t = 0.0
	_set_level(_script_levels[0])


func _advance_script(dt: float) -> void:
	_script_t += dt
	while _script_i < _script_levels.size() - 1 and _script_t >= _script_secs[_script_i]:
		_script_t -= _script_secs[_script_i]
		_script_i += 1
	_set_level(_script_levels[_script_i])


func _set_level(l: int) -> void:
	var nl := clampi(l, 0, STATES.size() - 1)
	if nl == _level:
		return
	_level = nl
	changed.emit(STATES[nl])
