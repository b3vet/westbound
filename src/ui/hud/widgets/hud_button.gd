class_name HudButton
extends BaseButton
## The HUD's pause [II] and camera [CAM] buttons, top-right. Spec: UI → HUD elements
## ("Top-right: ... pause and camera buttons"); Design system (faceted small controls,
## 7 px bevel, neon edge switching to the accent when pressed). The only HUD pieces
## that take touches (mouse_filter STOP); everything else lets touches through.

enum Glyph { PAUSE, CAMERA }

const LABEL_CAMERA := "CAM"

@export var glyph: Glyph = Glyph.PAUSE

var style: HudStyle
var _mesh := HudMesh.new()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	action_mode = BaseButton.ACTION_MODE_BUTTON_RELEASE


func setup(s: HudStyle) -> void:
	style = s
	queue_redraw()


## Shapes as one triangle array (one draw call), then the CAM label.
func _draw() -> void:
	if style == null:
		return
	var s := style
	var mode := get_draw_mode()
	var down := mode == DRAW_PRESSED or mode == DRAW_HOVER_PRESSED
	var fill := Color(s.ink, 1.0) if down else s.panel_fill
	var edge := s.accent if down or mode == DRAW_HOVER else s.edge_idle
	var ink := s.accent if down else s.text
	var c := size * 0.5
	_mesh.begin()
	_mesh.panel(Rect2(Vector2.ZERO, size), s.bevel_control, fill, edge, s.edge_w)
	if glyph == Glyph.PAUSE:
		var h := HudDraw.cap_height(s.size_button) * PAUSE_HEIGHT
		var w := h * PAUSE_BAR
		var gap := w
		_mesh.rect(Rect2(Vector2(c.x - gap * 0.5 - w, c.y - h * 0.5), Vector2(w, h)), ink)
		_mesh.rect(Rect2(Vector2(c.x + gap * 0.5, c.y - h * 0.5), Vector2(w, h)), ink)
	_mesh.flush(self)
	if glyph == Glyph.CAMERA:
		var tw := HudDraw.text_width(s.label, LABEL_CAMERA, s.size_button)
		HudDraw.text(self, s.label, Vector2(c.x - tw * 0.5, c.y + HudDraw.cap_height(s.size_button) * 0.5),
				LABEL_CAMERA, s.size_button, ink)


const PAUSE_HEIGHT := 1.3   # lint: allow-number glyph proportion
const PAUSE_BAR := 0.28   # lint: allow-number glyph proportion
