extends CanvasLayer
## Live sky_t debug slider. Spec: World → Color script ("a debug slider scrubs
## sky_t live"). Drop it into any scene with a SkyRig: it finds the rig through
## `sky_path` or the SkyRig group. Dragging sets sky_t; "play" runs the whole
## timeline in `cycle_s` seconds. When neither is active the slider only mirrors
## sky_t, so it never fights the sun clock. The readout shows the nearest
## keyframe and is tinted with the current UI accent.

## Optional path to the SkyRig; empty = first node in SkyRig.GROUP.
@export var sky_path: NodePath
## Seconds for one full morning -> morning cycle while playing.
@export var cycle_s: float = 40.0
@export var start_playing: bool = false

@onready var _slider: HSlider = $Panel/Row/Slider
@onready var _value: Label = $Panel/Row/Value
@onready var _play: Button = $Panel/Row/Play

var _sky: SkyRig
var _shown_t: float = -1.0


func _ready() -> void:
	_slider.value_changed.connect(_on_slider)
	_play.toggled.connect(_on_play)
	_play.button_pressed = start_playing


func _process(delta: float) -> void:
	if _sky == null or not is_instance_valid(_sky):
		_sky = _find_sky()
		if _sky == null:
			return
	if _play.button_pressed and cycle_s > 0.0:
		_sky.sky_t = fposmod(_sky.sky_t + delta / cycle_s, 1.0)
	if _sky.sky_t != _shown_t:
		_shown_t = _sky.sky_t
		_slider.set_value_no_signal(_shown_t)
		_value.text = "%.3f %s" % [_shown_t, _sky.color_script.nearest_key(_shown_t)]
		_value.add_theme_color_override(&"font_color", _sky.get_accent())


## The rig this slider drives (null until one is found).
func get_sky() -> SkyRig:
	return _sky


func _find_sky() -> SkyRig:
	if not sky_path.is_empty():
		return get_node_or_null(sky_path) as SkyRig
	return get_tree().get_first_node_in_group(SkyRig.GROUP) as SkyRig


func _on_slider(v: float) -> void:
	if _sky != null:
		_sky.sky_t = v


func _on_play(on: bool) -> void:
	_play.text = "pause" if on else "play"
