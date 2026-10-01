extends WBTest
## Dev buttons on phones (WP9.10): DriveControls (the drive scenes, the run's dev rows,
## the traffic sandbox's tabs and panels) places its rows inside
## ScreenInsets.canvas_safe_rect, the HUD's source (WP9.7), so nothing sits under the
## camera cutout; no dev overlay computes its own safe area.

## The review snaps' notched phone (--safe_insets=85,0,0,21 on 1560x720): the camera
## cutout on the left, a home-indicator strip at the bottom.
const FULL := Rect2(0.0, 0.0, 1560.0, 720.0)
const INSETS := Vector4(85.0, 0.0, 0.0, 21.0)
const TOL := 0.5

var _controls: DriveControls


func after_each() -> void:
	if _controls != null:
		_controls.free()
		_controls = null


func _make() -> DriveControls:
	_controls = DriveControls.new()
	var noop := func() -> void: pass
	for corner: int in [DriveControls.Corner.TOP_LEFT, DriveControls.Corner.TOP_RIGHT,
			DriveControls.Corner.BOTTOM_LEFT, DriveControls.Corner.BOTTOM_RIGHT]:
		_controls.add_button(corner, 0, "A", DriveControls.WIDE, noop)
		_controls.add_button(corner, 0, "B", DriveControls.SQUARE, noop)
		_controls.add_button(corner, 1, "C", DriveControls.WIDE, noop, true)
	tree.root.add_child(_controls)
	return _controls


static func _buttons(n: Node, out: Array[Control]) -> void:
	if n is Button:
		out.append(n as Control)
	for ch in n.get_children():
		_buttons(ch, out)


func test_safe_rect_is_the_huds() -> void:
	var dc := _make()
	await tree.process_frame
	var full := dc.get_viewport().get_visible_rect()
	eq(dc.safe_rect(), ScreenInsets.canvas_safe_rect(full), "ScreenInsets, as the HUD")
	eq(dc.safe_rect(), HudLayout.canvas_safe_rect(full))


func test_rows_stay_inside_a_notched_safe_area() -> void:
	var dc := _make()
	await tree.process_frame
	var safe := ScreenInsets.safe_rect(FULL, INSETS)
	dc.layout_in(safe)
	await tree.process_frame   # the rows sort their buttons
	var buttons: Array[Control] = []
	_buttons(dc, buttons)
	eq(buttons.size(), 12)
	var left := INF
	var bottom := -INF
	for b in buttons:
		var r := b.get_global_rect()
		check(safe.grow(TOL).encloses(r), "%s at %s inside the safe area %s" % [(b as Button).text, r, safe])
		left = minf(left, r.position.x)
		bottom = maxf(bottom, r.end.y)
	# The left rows start just inside the inset, clear of the camera cutout; the bottom
	# rows sit above the strip.
	near(left, INSETS.x + DriveControls.MARGIN_PX, TOL, "left rows at the inset + margin")
	near(bottom, FULL.end.y - INSETS.w - DriveControls.MARGIN_PX, TOL, "bottom rows above the strip")


## Every dev overlay goes through ScreenInsets: none reads the display's safe area
## itself (the web shell's insets and the phone minimum would be missed).
func test_no_dev_overlay_computes_its_own_safe_area() -> void:
	var files := PackedStringArray()
	_dev_scripts("res://src", false, files)
	gt(files.size(), 10, "dev scripts found")
	check(files.has("res://src/dev/drive_controls.gd") and files.has("res://src/traffic/dev/traffic_sandbox.gd"))
	for f in files:
		var text := FileAccess.get_file_as_string(f)
		check(not text.contains("get_display_safe_area"), "%s: use ScreenInsets.canvas_safe_rect" % f)


## .gd files under any `dev` folder of `dir` (`in_dev`: already inside one).
static func _dev_scripts(dir: String, in_dev: bool, out: PackedStringArray) -> void:
	for f in DirAccess.get_files_at(dir):
		if in_dev and f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_dev_scripts(dir.path_join(d), in_dev or d == "dev", out)
