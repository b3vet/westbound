class_name HudTextProbe
extends RefCounted
## Records the text the HUD and the screens draw, for the text-fit tests (WP5.6). Spec:
## UI, HUD and design system (Accessibility: text size 100% / 125%; nothing overlaps).
## docs/HUD.md → Text fit.
##
##   var probe := HudTextProbe.new()
##   HudDraw.probe = probe          # every HudDraw.text / number (and the event stack) records
##   ... redraw, await a frame ...
##   HudDraw.probe = null
##
## Each record is the canvas item that drew it, the text's box in that item's local
## coordinates (from the baseline up one cap height, as wide as the advance), and the
## string. Off (HudDraw.probe == null) it costs one null check per drawn string.

var items: Array[CanvasItem] = []
var rects: Array[Rect2] = []
var texts := PackedStringArray()


func add(ci: CanvasItem, rect: Rect2, s: String) -> void:
	items.append(ci)
	rects.append(rect)
	texts.append(s)


func clear() -> void:
	items.clear()
	rects.clear()
	texts.clear()


func size() -> int:
	return items.size()


## Record i's box in canvas (global) coordinates.
func global_rect(i: int) -> Rect2:
	return items[i].get_global_transform() * rects[i]
