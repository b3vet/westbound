class_name ScreenPanel
extends Control
## A faceted screen panel: chamfered fill (13 px bevel), 1.5 px neon edge and the
## accent tab on its top edge, like the HUD's panels. Spec: UI, HUD and design system →
## Design system (faceted panels, neon edge; never frosted glass with no edge).
## One triangle array (HudMesh): one draw call. Never takes touches.

enum Edge { IDLE, ACCENT, GOLD }

var style: HudStyle
var edge: Edge = Edge.IDLE
## Fill opacity multiplier (1 = the tuned panel opacity).
var fill_alpha: float = 1.0
## Gold fill (the NEW BEST badge) instead of the panel color.
var gold_fill: bool = false
var tab: bool = true
var small_bevel: bool = false

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
	if style == null:
		return
	var s := style
	var e := s.edge_idle
	if edge == Edge.ACCENT:
		e = s.accent
	elif edge == Edge.GOLD:
		e = s.gold
	var fill := Color(s.gold, 1.0) if gold_fill else Color(s.panel_fill, s.panel_fill.a * fill_alpha)
	var bevel := s.bevel_control if small_bevel else s.bevel_panel
	_mesh.begin()
	_mesh.panel(Rect2(Vector2.ZERO, size), bevel, fill, e, s.edge_w)
	if tab:
		_mesh.rect(Rect2(Vector2(bevel + s.edge_w, s.edge_w), s.tuning.accent_tab_size_px),
				s.gold if edge == Edge.GOLD else s.accent)
	_mesh.flush(self)
