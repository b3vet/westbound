class_name GarageItemButton
extends ScreenButton
## One item in the garage's lists (WP8.2): a car slot, a paint or a rim. An OPTION
## ScreenButton (the selected one accent-tinted with its tab) whose note line carries the
## unlock rule while locked ("LEVEL 4", "REACH LEG 4"); a locked item draws dimmed but
## still takes the tap, which previews it on the turntable without selecting it. A paint
## also draws its colour chip at the right end; its name is always shown (colour is never
## the only cue). Spec: Garage and progression; Design system; Accessibility (colour
## independence). Touch: BaseButton's emulated mouse events, never a raw touch index.

## The catalog id (a slot id, a paint id or a rim id).
var item_id: StringName = &""
var locked: bool = false:
	set(value):
		if value != locked:
			locked = value
			self_modulate = Color(1.0, 1.0, 1.0, LOCKED_A) if value else Color.WHITE
			queue_redraw()
## A paint chip (sRGB) at the right end, when has_swatch.
var has_swatch: bool = false
var swatch: Color = Color.WHITE:
	set(value):
		if not value.is_equal_approx(swatch):
			swatch = value
			queue_redraw()
## Share of the width the chip takes (GarageScreen sets it from tuning).
var swatch_frac: float = 0.2

var _chip_mesh := HudMesh.new()


static func make_item(id: StringName, label: String, base_px: int) -> GarageItemButton:
	var b := GarageItemButton.new()
	b.item_id = id
	b.text = label
	b.kind = ScreenButton.Kind.OPTION
	b.size_px = base_px
	b.align = HORIZONTAL_ALIGNMENT_LEFT
	b.name = "Item_%s" % id
	return b


## The chip's rect inside the button (empty without a swatch).
func swatch_rect() -> Rect2:
	if not has_swatch or style == null:
		return Rect2()
	var pad := style.tuning.spacing_grid_px * 2.0
	var h := size.y - pad * 2.0
	var w := size.x * swatch_frac
	return Rect2(Vector2(size.x - pad - w, (size.y - h) * 0.5), Vector2(w, h))


## The label's right end (canvas px, the button's own space): the chip must clear it.
func label_end() -> float:
	if style == null:
		return 0.0
	return style.tuning.spacing_grid_px * 2.0 + HudDraw.text_width(style.label, text, font_px())


func _draw() -> void:
	super._draw()
	if not has_swatch or style == null:
		return
	_chip_mesh.begin()
	_chip_mesh.panel(swatch_rect(), style.bevel_control * CHIP_BEVEL, swatch,
			style.text if selected else style.edge_idle, style.edge_w)
	_chip_mesh.flush(self)


## A locked item's opacity; the chip's bevel as a share of a control's.
const LOCKED_A := 0.62   # lint: allow-number look
const CHIP_BEVEL := 0.6   # lint: allow-number look
