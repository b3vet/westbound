extends Node
## Player settings (autoload `Settings`). Spec: Controls → Settings and first run
## (steering and throttle mode, sensitivity, dead zone, curve, left-handed mirror,
## haptics, units); Cameras ("the choice is saved"; reduced motion); Performance budget
## (quality tier, battery saver); Audio (a volume per bus); Accessibility (text size);
## UI → Screens → Settings. Plan D9 / D10 (controls size, drag visual), D22 (defaults:
## drag + manual, wheel look, owner 2026-10-01), D11 (the cockpit camera hidden from
## players). docs/SAVE.md → Settings.
##
## A typed key/value store with defaults. set_value() emits Events.settings_changed,
## and every system applies its keys live from that signal (nobody polls). Persistence
## goes through `Save` (the "settings" section of the save document), which also
## autosaves after a change (docs/SAVE.md → When it writes).
##
## Loading is defensive (from_dict): a value of the wrong type, an unknown choice or a
## non-finite number falls back to the default, so a damaged save never feeds a system
## a value it cannot handle. A camera mode players cannot pick (the hidden cockpit)
## loads as its fallback (CameraTuning.player_mode). Ranges (sensitivity, sizes,
## volumes) are clamped by the systems that read them, from their tuning. Keys this build does not know are kept
## and written back (a newer build's settings survive a downgrade and upgrade).

const DEFAULTS := {
	&"steering_mode": &"drag",      # &"drag" | &"gyro"
	## Owner, 2026-10-01 (plan D22): drag + manual pedals by default (the spec's: auto).
	&"throttle_mode": &"manual",    # &"auto" | &"manual"
	&"left_handed": false,
	## Steering feel multipliers (1.0 = the spec's tuned values; clamped 0.5-2 by PlayerInput).
	&"steer_sensitivity": 1.0,
	&"steer_dead_zone": 1.0,
	&"steer_curve": 1.0,
	## Drag-steering visual: &"ring" (anchor ring + thumb dot) | &"wheel" (steering wheel that
	## turns). Owner, 2026-10-01 (plan D10): the wheel by default.
	&"drag_visual": &"wheel",
	## On-screen control size multiplier (touch pedals, buttons, anchor visuals).
	&"controls_scale": 1.0,
	&"haptics": true,
	&"units": &"kmh",               # &"kmh" | &"mph"
	## One of CameraTuning.modes (the rig ignores an unknown one). Loading keeps only the
	## modes players can pick (CameraTuning.player_mode: a saved cockpit loads as hood while
	## the cockpit is hidden, plan D11).
	&"camera_mode": &"chase",
	&"reduced_motion": false,
	&"quality_tier": &"medium",     # &"low" | &"medium" | &"high"
	&"battery_saver": false,
	&"text_scale": 1.0,
	## Audio bus volumes (WP7A): linear 0..1 on top of AudioTuning's bus levels; 0 mutes
	## the bus. audio_muted mutes everything (the M key flips it).
	&"volume_master": 1.0,
	&"volume_music": 1.0,
	&"volume_sfx": 1.0,
	&"volume_engine": 1.0,
	&"volume_ui": 1.0,
	&"audio_muted": false,
}

## Keys whose value must be one of a fixed set (anything else loads as the default).
const CHOICES := {
	&"steering_mode": [&"drag", &"gyro"],
	&"throttle_mode": [&"auto", &"manual"],
	&"drag_visual": [&"ring", &"wheel"],
	&"units": [&"kmh", &"mph"],
	&"quality_tier": [&"low", &"medium", &"high"],
}

const KEY_CAMERA := &"camera_mode"

var _values := {}
## Keys from a save this build does not know (written back unchanged).
var _unknown := {}


func _init() -> void:
	reset_to_defaults()


## Every key back to its default, silently (tests; a fresh save). Unknown keys are
## forgotten.
func reset_to_defaults() -> void:
	_values = DEFAULTS.duplicate()
	_unknown = {}


## Every key back to its default, announcing each one that changes (the systems follow).
## Tests use this to leave no stale value in a system's cache.
func restore_defaults() -> void:
	from_dict({}, true)


func get_value(key: StringName) -> Variant:
	assert(DEFAULTS.has(key), "Unknown setting %s" % key)
	return _values[key]


func set_value(key: StringName, value: Variant) -> void:
	assert(DEFAULTS.has(key), "Unknown setting %s" % key)
	# Keep the default's type (a String choice becomes a StringName, an int a float).
	var d: Variant = DEFAULTS[key]
	if d is StringName and value is String:
		value = StringName(value)
	elif d is float and value is int:
		value = float(value)
	if _values[key] == value:
		return
	_values[key] = value
	Events.settings_changed.emit(key)


## The settings as a JSON-ready dictionary (keys as Strings), unknown keys included.
func to_dict() -> Dictionary:
	var out := _unknown.duplicate()
	for key: StringName in _values:
		var v: Variant = _values[key]
		out[String(key)] = String(v) if v is StringName else v
	return out


## Loads a saved dictionary: each known key is sanitized (sanitize()), unknown keys are
## kept for to_dict(). Emits settings_changed for every key whose value changed, so the
## systems already running apply it live. Keys missing from `data` keep their value, or
## go back to their default with `fill_defaults` (loading a whole save).
func from_dict(data: Dictionary, fill_defaults: bool = false) -> void:
	var incoming := {}
	if fill_defaults:
		_unknown = {}
		incoming = DEFAULTS.duplicate()
	for raw: Variant in data:
		var key := StringName(str(raw))
		if not DEFAULTS.has(key):
			_unknown[str(raw)] = data[raw]
			continue
		incoming[key] = sanitize(key, data[raw])
	var changed: Array[StringName] = []
	for key: StringName in incoming:
		var v: Variant = incoming[key]
		if not (_values[key] == v and typeof(_values[key]) == typeof(v)):
			_values[key] = v
			changed.append(key)
	for key in changed:
		Events.settings_changed.emit(key)


## `value` as the type of `key`'s default (StringName choices, bool, float), or the
## default when it cannot be one.
static func sanitize(key: StringName, value: Variant) -> Variant:
	var d: Variant = DEFAULTS[key]
	match typeof(d):
		TYPE_BOOL:
			return value if value is bool else d
		TYPE_FLOAT:
			if (value is float or value is int) and is_finite(float(value)):
				return float(value)
			return d
		TYPE_STRING_NAME:
			if not (value is String or value is StringName):
				return d
			var s := StringName(value)
			if CHOICES.has(key) and not (CHOICES[key] as Array).has(s):
				return d
			if key == KEY_CAMERA:
				return Tuning.load_default().camera.player_mode(s)
			return s if not String(s).is_empty() else d
	return d
