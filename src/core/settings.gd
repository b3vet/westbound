extends Node
## Player settings (autoload `Settings`). Spec: Controls → Settings, UI → Screens.
##
## M0 skeleton: typed key/value store with defaults and change signals.
## Persistence goes through `Save`; the full settings list lands in WP8.1.

const DEFAULTS := {
	&"steering_mode": &"drag",      # &"drag" | &"gyro"
	&"throttle_mode": &"auto",      # &"auto" | &"manual"
	&"left_handed": false,
	## Steering feel multipliers (1.0 = the spec's tuned values; clamped 0.5-2 by PlayerInput).
	&"steer_sensitivity": 1.0,
	&"steer_dead_zone": 1.0,
	&"steer_curve": 1.0,
	## Drag-steering visual: &"ring" (anchor ring + thumb dot) | &"wheel" (steering wheel that turns).
	&"drag_visual": &"ring",
	## On-screen control size multiplier (touch pedals, buttons, anchor visuals).
	&"controls_scale": 1.0,
	&"haptics": true,
	&"units": &"kmh",               # &"kmh" | &"mph"
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

var _values := {}


func _init() -> void:
	reset_to_defaults()


func reset_to_defaults() -> void:
	_values = DEFAULTS.duplicate()


func get_value(key: StringName) -> Variant:
	assert(DEFAULTS.has(key), "Unknown setting %s" % key)
	return _values[key]


func set_value(key: StringName, value: Variant) -> void:
	assert(DEFAULTS.has(key), "Unknown setting %s" % key)
	if _values[key] == value:
		return
	_values[key] = value
	Events.settings_changed.emit(key)


func to_dict() -> Dictionary:
	return _values.duplicate()


func from_dict(data: Dictionary) -> void:
	for key: Variant in data:
		if DEFAULTS.has(StringName(key)):
			_values[StringName(key)] = data[key]
