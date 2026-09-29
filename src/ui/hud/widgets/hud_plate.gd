class_name HudPlate
extends Control
## A HUD widget's shapes, drawn behind its text as one triangle array (HudMesh): one
## draw call for the whole panel. Redrawn only when the shapes change (a new lit
## segment, the sun marker moving a pixel, an icon animating), not when the text does.
## Spec: Performance budget; UI → HUD elements (update rule).

var widget: HudWidget
var mesh := HudMesh.new()
var redraws: int = 0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	show_behind_parent = true


func _draw() -> void:
	redraws += 1
	if widget == null or widget.style == null:
		return
	mesh.begin()
	widget._paint_plate(mesh)
	mesh.flush(self)
