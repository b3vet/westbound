extends Control
## The loop editor (N3.1 dev tool, not shipped): generate the multiplayer loop from a
## seed, hand-adjust it, preview traffic on it, export the road-space file. Spec:
## WESTBOUND_MULTIPLAYER_HANDOFF.md → The loop map ("Editor tool (Godot): generate the
## loop from a seed, adjust curve radii, crests, tunnel and bridge placement, and lane
## changes by hand, preview traffic in the sandbox, then export both the client scene
## data and the road-space file"). docs/LOOP_MAP.md → Editor.
##
## Run the scene (F6 in the Godot editor, or tools/godot.sh --path . <this scene>):
##   - left: LoopPlot (top-down plan + elevation strip); drag the square handles along
##     the loop to move tunnel portals, sector gantries (sector 3 is the bridge), ramps,
##     road works and lane changes; wheel zooms, right drag pans;
##   - right: the seed, every tunable parameter (bend radii / deflections / transitions,
##     straight weights, PVI raises = crest heights and vertical radii, tunnel portals and
##     lengths, lane-change points, sector offsets, ramps, road works) as numeric fields,
##     filtered by group; edited ones are highlighted, x drops the edit;
##   - the validation list and the export hash update after every change;
##   - SAVE writes the seed and the edit list to data/maps/loop_v1.tres (the client scene
##     data), EXPORT writes the road-space JSON (both copies) and the .sha256 sidecars
##     (refused while the loop has errors), CHECK compares them with a fresh export,
##     PREVIEW TRAFFIC opens the traffic sandbox on the edited loop.
##
## Headless (CI, scripts), from the repo root:
##   tools/godot.sh --headless --path . res://src/road/loop/dev/loop_editor.tscn -- --export
##   tools/godot.sh --headless --path . res://src/road/loop/dev/loop_editor.tscn -- --check
## --export regenerates from data/maps/loop_v1.tres and writes the files (exit 1 on
## validation errors); --check exits 1 when the committed files are not current.
## Snap: tools/snap.sh src/road/loop/dev/loop_editor.tscn --size=1600x1000 [--select=<key>]
## [--group=<group>] [--zoom=<x>].

const SANDBOX_SCENE := "res://src/traffic/dev/traffic_sandbox.tscn"
## Laps of biome plan the traffic preview gets (it runs on unwrapped s).
const PREVIEW_LAPS := 40
const PANEL_WIDTH_PX := 460.0
const ROW_LABEL_PX := 230.0
const GROUPS: Array[String] = ["all", "bend", "straight", "pvi", "tunnel", "lanes", "sector", "ramp", "closure"]
const EDITED := Color(1.0, 0.8, 0.3)
const PLAIN := Color(0.85, 0.87, 0.9)
const COL_ERROR := Color(1.0, 0.45, 0.4)
const COL_OK := Color(0.5, 1.0, 0.6)
const FINE_STEP := 0.1
const COARSE_STEP := 1.0

var def: LoopMapDef
var tuning: Tuning
var road: LoopRoadPath
var errors := PackedStringArray()
var plot: LoopPlot
var export_hash: String = ""

var _keys := PackedStringArray()
var _fields: Dictionary = {}   ## key -> SpinBox
var _labels: Dictionary = {}   ## key -> Label
var _rows: Dictionary = {}     ## key -> HBoxContainer
var _group: String = "all"
var _dirty: bool = false
var _updating: bool = false
var _list: VBoxContainer
var _scroll: ScrollContainer
var _status: Label
var _issues: Label
var _seed_box: SpinBox
var _groups: OptionButton
var _message: String = ""


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("--export") or args.has("--check"):
		_run_cli(args)
		return
	set_anchors_preset(Control.PRESET_FULL_RECT)
	tuning = Tuning.load_default()
	def = LoopMapDef.load_default().duplicate(true) as LoopMapDef
	_build_ui()
	regenerate()


func snap_setup(args: Dictionary) -> void:
	if args.has("group"):
		set_group(String(args["group"]))
	if args.has("zoom"):
		plot.zoom = float(args["zoom"])
	if args.has("select"):
		_select(String(args["select"]))
	plot.queue_redraw()
	await get_tree().process_frame


func _process(_delta: float) -> void:
	if _dirty:
		_dirty = false
		regenerate()


# ---------------------------------------------------------------- Headless

func _run_cli(args: PackedStringArray) -> void:
	var t := Tuning.load_default()
	var r := LoopRoadPath.load_default(t)
	var code := 0
	if args.has("--export"):
		var errs := LoopExport.write_all(r, t)
		for e in errs:
			printerr("loop_editor: ", e)
		if errs.is_empty():
			print("loop_editor: exported %s  sha256 %s" % [", ".join(LoopExport.paths(r)),
				LoopExport.sha256_hex(LoopExport.to_json(r))])
		else:
			code = 1
	if args.has("--check"):
		var diffs := LoopExport.check_current(r)
		for e in diffs:
			printerr("loop_editor: ", e)
		if diffs.is_empty():
			print("loop_editor: committed files are current  sha256 %s" % LoopExport.sha256_hex(LoopExport.to_json(r)))
		else:
			code = 1
	get_tree().quit(code)


# ---------------------------------------------------------------- Model

## Rebuilds the loop from `def` (seed + edits), validates it, refreshes the view.
func regenerate() -> void:
	road = LoopRoadPath.new(def, tuning)
	errors = LoopValidator.validate(road, tuning)
	export_hash = LoopExport.sha256_hex(LoopExport.to_json(road))
	plot.set_road(road)
	_refresh_fields()
	_refresh_status()


func set_edit(key: String, value: float) -> void:
	def.edits[key] = value
	_dirty = true


func clear_edit(key: String) -> void:
	def.edits.erase(key)
	_dirty = true


## Writes the seed and the edits into data/maps/loop_v1.tres (the file as loaded, so its
## sub-resource ids and the rest of its data stay as they are).
func save_edits() -> Error:
	var base := ResourceLoader.load(LoopMapDef.DEFAULT_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as LoopMapDef
	base.map_seed = def.map_seed
	base.edits = def.edits.duplicate()
	var err := ResourceSaver.save(base, LoopMapDef.DEFAULT_PATH)
	_message = "saved %s" % LoopMapDef.DEFAULT_PATH if err == OK else "save failed: %s" % error_string(err)
	_refresh_status()
	return err


func export_files() -> PackedStringArray:
	var errs := LoopExport.write_all(road, tuning)
	_message = "exported (sha256 %s)" % export_hash if errs.is_empty() else "export refused: %d errors" % errs.size()
	_refresh_status()
	return errs


func check_files() -> PackedStringArray:
	var diffs := LoopExport.check_current(road)
	_message = "committed files are current" if diffs.is_empty() else "; ".join(diffs)
	_refresh_status()
	return diffs


## Opens the traffic sandbox on the edited loop (its road injection hook).
func preview_traffic() -> Node:
	var sb := (load(SANDBOX_SCENE) as PackedScene).instantiate()
	sb.set(&"road_override", LoopRoadPath.new(def, tuning))
	sb.set(&"biome_plan_override", road.biome_plan(PREVIEW_LAPS))
	var tree := get_tree()
	tree.root.add_child(sb)
	tree.current_scene = sb
	queue_free()
	return sb


func set_group(group: String) -> void:
	_group = group if GROUPS.has(group) else "all"
	if _groups != null:
		_groups.select(GROUPS.find(_group))
	for key: String in _rows:
		(_rows[key] as Control).visible = _group == "all" or key.begins_with(_group + "/")


# ---------------------------------------------------------------- UI

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = LoopPlot.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	var split := HBoxContainer.new()
	split.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(split)
	plot = LoopPlot.new()
	plot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	plot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(plot)
	plot.param_dragged.connect(set_edit)
	plot.param_selected.connect(_select)
	var panel := VBoxContainer.new()
	panel.custom_minimum_size = Vector2(PANEL_WIDTH_PX, 0.0)
	split.add_child(panel)
	var title := Label.new()
	title.text = "LOOP EDITOR  %s" % def.map_id
	panel.add_child(title)
	var seed_row := HBoxContainer.new()
	panel.add_child(seed_row)
	var seed_label := Label.new()
	seed_label.text = "seed"
	seed_row.add_child(seed_label)
	_seed_box = SpinBox.new()
	_seed_box.min_value = 0
	_seed_box.max_value = 1 << 30
	_seed_box.value = def.map_seed
	_seed_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seed_row.add_child(_seed_box)
	_button(seed_row, "GENERATE", func() -> void:
		def.map_seed = int(_seed_box.value)
		_keys = PackedStringArray()
		_dirty = true)
	_groups = OptionButton.new()
	for g in GROUPS:
		_groups.add_item(g)
	_groups.item_selected.connect(func(i: int) -> void: set_group(GROUPS[i]))
	panel.add_child(_groups)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(_scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_list)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(_status)
	_issues = Label.new()
	_issues.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(_issues)
	var buttons := HFlowContainer.new()
	panel.add_child(buttons)
	_button(buttons, "SAVE", func() -> void: save_edits())
	_button(buttons, "EXPORT", func() -> void: export_files())
	_button(buttons, "CHECK", func() -> void: check_files())
	_button(buttons, "RESET EDITS", func() -> void:
		def.edits.clear()
		_dirty = true)
	_button(buttons, "PREVIEW TRAFFIC", func() -> void: preview_traffic())


func _button(parent: Control, text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(action)
	parent.add_child(b)
	return b


## Builds the rows when the parameter set changed, else updates their values.
func _refresh_fields() -> void:
	var o := road.layout
	_updating = true
	if o.param_key != _keys:
		_keys = o.param_key.duplicate()
		for c in _list.get_children():
			c.free()
		_fields.clear()
		_labels.clear()
		_rows.clear()
		for i in o.param_key.size():
			_add_row(i)
		set_group(_group)
	for i in o.param_key.size():
		var key := o.param_key[i]
		var box: SpinBox = _fields[key]
		box.value = o.param_value[i]
		(_labels[key] as Label).add_theme_color_override(&"font_color", EDITED if def.edits.has(key) else PLAIN)
	_updating = false


func _add_row(i: int) -> void:
	var o := road.layout
	var key := o.param_key[i]
	var row := HBoxContainer.new()
	_list.add_child(row)
	var label := Label.new()
	label.text = key
	label.custom_minimum_size = Vector2(ROW_LABEL_PX, 0.0)
	label.tooltip_text = "generated %.3f, range %.1f..%.1f, at s %.0f" % [o.param_default[i], o.param_min[i],
		o.param_max[i], o.param_s[i]]
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(label)
	var box := SpinBox.new()
	var step := FINE_STEP if key.ends_with("_deg") or key.ends_with("weight") or key.ends_with("raise_m") else COARSE_STEP
	# Whole-number range ends, so the values the SpinBox snaps to are the round ones.
	var lo := floorf(minf(o.param_min[i], o.param_value[i]))
	var hi := ceilf(maxf(o.param_max[i], o.param_value[i]))
	box.step = step
	box.min_value = lo
	box.max_value = hi if hi > lo else lo + step
	box.allow_greater = true
	box.allow_lesser = true
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.value_changed.connect(func(v: float) -> void:
		if not _updating:
			set_edit(key, v))
	box.get_line_edit().focus_entered.connect(func() -> void: _select(key, false))
	row.add_child(box)
	_button(row, "x", func() -> void: clear_edit(key))
	_fields[key] = box
	_labels[key] = label
	_rows[key] = row


func _select(key: String, scroll: bool = true) -> void:
	plot.selected_key = key
	plot.queue_redraw()
	if scroll and _rows.has(key):
		if not (_rows[key] as Control).visible:
			set_group("all")
		_scroll.ensure_control_visible.call_deferred(_rows[key])


func _refresh_status() -> void:
	if _status == null:
		return
	var o := road.layout
	_status.text = "L %.0f m   closure %s m in %d steps   heading %s rad\nsha256 %s\n%s" % [
		road.length(), String.num_scientific(o.closure_residual_m), o.closure_iterations,
		String.num_scientific(o.closure_heading_error), export_hash, _message]
	if errors.is_empty():
		_issues.text = "VALID  (%d edits)" % def.edits.size()
		_issues.add_theme_color_override(&"font_color", COL_OK)
	else:
		_issues.text = "%d ERRORS\n%s" % [errors.size(), "\n".join(errors)]
		_issues.add_theme_color_override(&"font_color", COL_ERROR)
