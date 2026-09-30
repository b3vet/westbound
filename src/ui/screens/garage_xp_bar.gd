class_name GarageXpBar
extends Control
## The driver level's progress bar (WP8.2): a slanted track with the accent fill, gold
## when `gold` (a level-up on the results). Spec: Garage and progression (driver level);
## Design system (faceted, speed-tilted shapes, no gradients). One triangle array
## (HudMesh): one draw call; redraws only when the value or the look changes. Used by
## the garage's header and the results' XP panel. Never takes touches.

var style: HudStyle
## 0 to 1.
var frac: float = 0.0:
	set(value):
		var v := clampf(value, 0.0, 1.0)
		if not is_equal_approx(v, frac):
			frac = v
			queue_redraw()
var gold: bool = false:
	set(value):
		if value != gold:
			gold = value
			queue_redraw()

var _mesh := HudMesh.new()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE


func setup(s: HudStyle) -> void:
	style = s
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


func _draw() -> void:
	if style == null or size.x <= 0.0:
		return
	var lean := size.y * tan(absf(style.tilt_rad))
	var r := Rect2(Vector2.ZERO, Vector2(maxf(size.x - lean, 0.0), size.y))
	_mesh.begin()
	_mesh.slant(r, lean, Color(style.ink, 1.0))
	if frac > 0.0:
		_mesh.slant(Rect2(r.position, Vector2(r.size.x * frac, r.size.y)), lean, style.gold if gold else style.accent)
	_mesh.flush(self)
