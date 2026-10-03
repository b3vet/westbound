class_name GarageScreen
extends RunScreen
## The garage (WP8.2). Spec: UI → Screens ("Garage: car select, paint and rims (see
## Cars)"); Garage and progression (8 roster slots, 1 unlocked at start; driver level;
## level and milestone unlocks; "The garage shows the car on a turntable with the current
## sky palette"); Design system (left-anchored, faceted, speed-tilted titles); Accessibility
## (text size 100% / 125%; colour never the only cue). docs/GARAGE.md, docs/SCREENS.md →
## Garage.
##
## Over the title's attract drive (TitleScreens builds it on first use):
##   - top row: GARAGE (display face, speed-tilted), the driver level with its XP bar,
##     DONE (primary) top-right;
##   - left: the tabs CAR / PAINT / RIMS and the current tab's items (GarageItemButton):
##     the 8 roster slots, the paints (named, with a chip), the rims;
##   - right: the turntable (GarageTurntable) with the car's name, its state line
##     (SELECTED, or what unlocks it) and its stats under it.
## A tap on an unlocked item selects it (saved at once through Garage.changed: the next
## run and the attract car use it); a tap on a locked one previews it on the turntable
## and names its unlock, but never selects it. Placeholder slots (no car yet) show as
## COMING SOON. Keys: Esc / Enter = DONE, Left / Right step through the items, Up / Down
## change the tab. Emits `done`; TitleScreens goes back to the title.

signal done()

enum Tab { CAR, PAINT, RIMS }

const TILT_SHADER := preload("res://src/ui/theme/speed_tilt.gdshader")
const TEXT_TITLE := "GARAGE"
const TEXT_DONE := "DONE"
const TAB_TEXTS: Array[String] = ["CAR", "PAINT", "RIMS"]
const TEXT_LEVEL := "DRIVER LEVEL %d"
const TEXT_XP := "%s / %s XP"
const TEXT_XP_MAX := "%s XP · MAX LEVEL"
const TEXT_SELECTED := "SELECTED"
const TEXT_UNLOCK_LEVEL := "LEVEL %d"
const TEXT_UNLOCK_LEG := "REACH LEG %d"
const TEXT_UNLOCK_COAST := "REACH THE COAST"
const TEXT_UNLOCK_STREAK := "%d-DAY DAILY STREAK"
const TEXT_UNLOCK_THREADS := "%d THREADS"
const TEXT_PROGRESS := "%s · %d/%d"
const TEXT_LOCKED := "LOCKED · %s"
const TEXT_PREVIEW := "PREVIEW · %s"
const TEXT_IN_THE_WORKS := "IN THE WORKS · %s"
const TEXT_STATS := "TOP %d %s  ·  0-%d IN %s S"
const UNIT_KMH := "KM/H"
const UNIT_MPH := "MPH"
## The acceleration stat's end speed (CarDef.zero_to_200_s).
const ZERO_TO_KMH := 200.0

var profile: MetaProfile
var catalog: GarageCatalog
var progression: ProgressionTuning
var tab: Tab = Tab.CAR
## A locked item on show (the selection is unchanged): a slot, paint or rim id.
var preview_id: StringName = &""
var miles: bool = false

var dim: ColorRect
var title_text: ScreenText
var level_text: ScreenText
var xp_text: ScreenText
var xp_bar: GarageXpBar
var done_button: ScreenButton
var tab_buttons: Array[ScreenButton] = []
var car_items: Array[GarageItemButton] = []
var paint_items: Array[GarageItemButton] = []
var rim_items: Array[GarageItemButton] = []
var turntable: GarageTurntable
var name_text: ScreenText
var note_text: ScreenText
var stats_text: ScreenText


func _init() -> void:
	super._init()
	name = "Garage"
	modal = true
	pad_focus = false   # the arrows (D-pad, stick) step items and tabs themselves
	dim = ColorRect.new()
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	turntable = GarageTurntable.new()
	turntable.name = "Turntable"
	add_child(turntable)
	title_text = ScreenText.make(TEXT_TITLE, ScreenText.Face.DISPLAY, 60, ScreenText.Ink.TEXT)
	title_text.name = "Title"
	title_text.outline = true
	add_child(title_text)
	level_text = ScreenText.make("", ScreenText.Face.LABEL, 16, ScreenText.Ink.TEXT)
	level_text.name = "Level"
	level_text.align = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(level_text)
	xp_bar = GarageXpBar.new()
	xp_bar.name = "XpBar"
	add_child(xp_bar)
	xp_text = ScreenText.make("", ScreenText.Face.LABEL, 13, ScreenText.Ink.MUTED)
	xp_text.name = "Xp"
	xp_text.tabular = true
	xp_text.align = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(xp_text)
	done_button = ScreenButton.make(TEXT_DONE, ScreenButton.Kind.PRIMARY, 24)
	done_button.name = "Done"
	done_button.pressed.connect(close_garage)
	add_child(done_button)
	for i in TAB_TEXTS.size():
		var b := ScreenButton.make(TAB_TEXTS[i], ScreenButton.Kind.OPTION, 24)
		b.name = "Tab%s" % TAB_TEXTS[i].capitalize()
		b.pressed.connect(show_tab.bind(i))
		add_child(b)
		tab_buttons.append(b)
	name_text = ScreenText.make("", ScreenText.Face.DISPLAY, 40, ScreenText.Ink.TEXT)
	name_text.name = "CarName"
	add_child(name_text)
	note_text = ScreenText.make("", ScreenText.Face.LABEL, 16, ScreenText.Ink.ACCENT)
	note_text.name = "Note"
	add_child(note_text)
	stats_text = ScreenText.make("", ScreenText.Face.LABEL, 16, ScreenText.Ink.MUTED)
	stats_text.name = "Stats"
	add_child(stats_text)


## Builds the items from the catalog (once) and styles them.
func _restyled() -> void:
	if progression == null:
		progression = Garage.tuning()
		catalog = Garage.catalog()
		turntable.setup(progression)
		_build_items()
	title_text.size_px = tuning.font_title_px
	title_text.use_tilt(TILT_SHADER, tuning.speed_tilt_rad())
	name_text.size_px = progression.garage_name_font_px
	name_text.use_tilt(TILT_SHADER, tuning.speed_tilt_rad())
	done_button.size_px = tuning.font_screen_button_px
	for b in tab_buttons:
		b.size_px = tuning.font_screen_button_px
	for b in car_items:
		b.size_px = progression.garage_item_font_px
	for b in rim_items:
		b.size_px = progression.garage_item_font_px
	for b in paint_items:
		b.size_px = progression.garage_paint_font_px
		b.swatch_frac = progression.garage_swatch_frac
	xp_bar.setup(style)
	dim.color = Color(style.ink, Units.pct_to_frac(tuning.screen_dim_pct))
	_layout()


func _build_items() -> void:
	for s in catalog.slots:
		var c := s.car()
		var b := GarageItemButton.make_item(s.id, c.display_name.to_upper() if c != null else GarageCatalog.TEXT_COMING_SOON,
				progression.garage_item_font_px)
		b.pressed.connect(pick.bind(s.id))
		add_child(b)
		car_items.append(b)
	for p in catalog.paints:
		var b := GarageItemButton.make_item(p.id, p.display_name, progression.garage_paint_font_px)
		b.has_swatch = true
		b.pressed.connect(pick.bind(p.id))
		add_child(b)
		paint_items.append(b)
	for r in catalog.rims:
		var b := GarageItemButton.make_item(r.id, r.display_name, progression.garage_item_font_px)
		b.pressed.connect(pick.bind(r.id))
		add_child(b)
		rim_items.append(b)
	for list: Array[GarageItemButton] in [car_items, paint_items, rim_items]:
		for b in list:
			b.setup(style)


# ---------------------------------------------------------------- Open / close

## Opens on the CAR tab with the saved selection on the turntable.
func open() -> void:
	profile = Garage.profile()
	miles = RunScreens._miles()
	reduced_motion = RunScreens._reduced_motion()
	tab = Tab.CAR
	preview_id = &""
	turntable.still = reduced_motion
	turntable.reset_yaw()
	turntable.set_active(true)
	refresh()
	super.open()
	var shown: Array[Control] = [title_text, level_text, xp_bar, xp_text]
	shown.append_array(_shown_items())
	for i in shown.size():
		slide_in(shown[i], -tuning.screen_slide_px, tuning.screen_fade_in_s, float(i) * tuning.results_row_stagger_s)


func _closed() -> void:
	turntable.set_active(false)


func close_garage() -> void:
	close(false)
	turntable.set_active(false)
	done.emit()


func show_tab(t: int) -> void:
	tab = clampi(t, 0, TAB_TEXTS.size() - 1) as Tab
	preview_id = &""
	refresh()


# ---------------------------------------------------------------- Picking

## A tap on item `id` in the current tab: selects it when unlocked (and saves), else
## previews it (a locked item is never selected).
func pick(id: StringName) -> void:
	if profile == null:
		return
	var ok := false
	match tab:
		Tab.CAR:
			ok = profile.select_car(id)
		Tab.PAINT:
			ok = profile.select_paint(edit_slot().id, id)
		Tab.RIMS:
			ok = profile.select_rim(edit_slot().id, id)
	if ok:
		preview_id = &""
		Garage.changed()
	else:
		preview_id = id
	refresh()


## Left / Right: the previous / next item of the tab (from the one on show).
func step(dir: int) -> void:
	var items := _shown_items()
	if items.is_empty():
		return
	var at := 0
	var on := shown_item_id()
	for i in items.size():
		if items[i].item_id == on:
			at = i
	pick(items[posmod(at + dir, items.size())].item_id)


## The slot whose paint and rims the PAINT and RIMS tabs change: the selected car.
func edit_slot() -> GarageSlot:
	return profile.selected_slot()


## The slot on the turntable (a previewed locked car, else the selected one).
func shown_slot() -> GarageSlot:
	if tab == Tab.CAR and preview_id != &"":
		var s := catalog.slot(preview_id)
		if s != null:
			return s
	return edit_slot()


## The item of the current tab on show (previewed or selected).
func shown_item_id() -> StringName:
	if preview_id != &"":
		return preview_id
	var s := edit_slot()
	match tab:
		Tab.PAINT:
			return profile.paint_for(s.id).id
		Tab.RIMS:
			return profile.rim_for(s.id).id
	return s.id


## The look on the turntable: the slot's saved look, with a previewed paint or rim.
func shown_look() -> CarLook:
	var s := shown_slot()
	var car := s.car()
	if tab == Tab.CAR and preview_id != &"":
		return CarLook.factory(car)
	var look := profile.look_for(s.id)
	if tab == Tab.PAINT and preview_id != &"":
		var p := catalog.paint(preview_id)
		if p != null:
			look.paint = p.color_for(car)
	elif tab == Tab.RIMS and preview_id != &"":
		var r := catalog.rim(preview_id)
		if r != null:
			look.rim = r
	return look


# ---------------------------------------------------------------- Refresh

## Every label, item state and the turntable from the profile.
func refresh() -> void:
	if profile == null or catalog == null:
		return
	var xp := profile.xp()
	var level := profile.level()
	level_text.text = TEXT_LEVEL % level
	var next := Progression.xp_to_reach(level + 1, progression)
	xp_text.text = TEXT_XP_MAX % HudFormat.thousands(xp) if level >= progression.max_level \
			else TEXT_XP % [HudFormat.thousands(xp), HudFormat.thousands(next)]
	xp_bar.frac = Progression.level_progress(xp, progression)
	for i in tab_buttons.size():
		tab_buttons[i].selected = i == tab
	var edit := edit_slot()
	for i in car_items.size():
		var s := catalog.slots[i]
		var b := car_items[i]
		b.locked = not profile.car_unlocked(s)
		b.selected = s == edit
		b.note = TEXT_SELECTED if s == edit else (requirement(s) if b.locked or not s.has_car() else "")
	var car := edit.car()
	for i in paint_items.size():
		var p := catalog.paints[i]
		var b := paint_items[i]
		b.locked = not profile.paint_unlocked(p)
		b.selected = profile.paint_for(edit.id) == p
		b.swatch = p.color_for(car)
		b.note = TEXT_UNLOCK_LEVEL % p.unlock_level if b.locked else ""
	for i in rim_items.size():
		var r := catalog.rims[i]
		var b := rim_items[i]
		b.locked = not profile.rim_unlocked(r)
		b.selected = profile.rim_for(edit.id) == r
		b.note = TEXT_UNLOCK_LEVEL % r.unlock_level if b.locked else ""
	for b in car_items:
		b.visible = tab == Tab.CAR
	for b in paint_items:
		b.visible = tab == Tab.PAINT
	for b in rim_items:
		b.visible = tab == Tab.RIMS
	_refresh_info()
	_layout()


func _refresh_info() -> void:
	var s := shown_slot()
	var car := s.car()
	if car == null:
		turntable.show_nothing()
		name_text.text = GarageCatalog.TEXT_COMING_SOON
		note_text.text = TEXT_IN_THE_WORKS % requirement(s)
		note_text.set_ink(ScreenText.Ink.MUTED)
		stats_text.text = ""
		return
	turntable.show_car(car, shown_look())
	name_text.text = car.display_name.to_upper()
	stats_text.text = stats_line(car)
	if preview_id == &"":
		note_text.text = TEXT_SELECTED
		note_text.set_ink(ScreenText.Ink.ACCENT)
		return
	note_text.set_ink(ScreenText.Ink.GOLD)
	match tab:
		Tab.CAR:
			note_text.text = TEXT_LOCKED % requirement(s)
		Tab.PAINT:
			var p := catalog.paint(preview_id)
			note_text.text = TEXT_PREVIEW % (TEXT_LOCKED % (TEXT_UNLOCK_LEVEL % p.unlock_level))
		Tab.RIMS:
			var r := catalog.rim(preview_id)
			note_text.text = TEXT_PREVIEW % (TEXT_LOCKED % (TEXT_UNLOCK_LEVEL % r.unlock_level))


## What unlocks slot `s`, with the progress for a counted milestone ("REACH LEG 4 · 2/4").
func requirement(s: GarageSlot) -> String:
	var p := profile.slot_progress(s) if profile != null else Vector2i.ZERO
	match s.unlock:
		GarageSlot.UNLOCK_START:
			return ""
		GarageSlot.UNLOCK_LEG:
			return TEXT_UNLOCK_LEG % progression.unlock_leg_milestone
		GarageSlot.UNLOCK_COAST:
			return TEXT_UNLOCK_COAST
		GarageSlot.UNLOCK_DAILY_STREAK:
			return TEXT_PROGRESS % [TEXT_UNLOCK_STREAK % progression.unlock_daily_streak_days, mini(p.x, p.y), p.y]
		GarageSlot.UNLOCK_THREADS:
			return TEXT_PROGRESS % [TEXT_UNLOCK_THREADS % progression.unlock_lifetime_threads, mini(p.x, p.y), p.y]
	return TEXT_UNLOCK_LEVEL % s.unlock_level


## "TOP 270 KM/H  ·  0-200 IN 8.8 S" (mph with the units setting).
func stats_line(car: CarDef) -> String:
	var top := Units.kmh_to_mph(car.top_speed_kmh) if miles else car.top_speed_kmh
	var to := Units.kmh_to_mph(ZERO_TO_KMH) if miles else ZERO_TO_KMH
	return TEXT_STATS % [roundi(top), UNIT_MPH if miles else UNIT_KMH, roundi(to), HudFormat.tenths_text(roundi(car.zero_to_200_s * HudFormat.TENTHS))]


func _shown_items() -> Array[GarageItemButton]:
	match tab:
		Tab.PAINT:
			return paint_items
		Tab.RIMS:
			return rim_items
	return car_items


func item(id: StringName) -> GarageItemButton:
	for b in _shown_items():
		if b.item_id == id:
			return b
	return null


# ---------------------------------------------------------------- Input

func _unhandled_input(event: InputEvent) -> void:
	if not visible or not is_open():
		return
	if event.is_action_pressed(&"ui_cancel") or event.is_action_pressed(&"ui_accept"):
		get_viewport().set_input_as_handled()
		close_garage()
	elif event.is_action_pressed(&"ui_left") or event.is_action_pressed(&"ui_right"):
		get_viewport().set_input_as_handled()
		step(-1 if event.is_action_pressed(&"ui_left") else 1)
	elif event.is_action_pressed(&"ui_up") or event.is_action_pressed(&"ui_down"):
		get_viewport().set_input_as_handled()
		show_tab(posmod(int(tab) + (-1 if event.is_action_pressed(&"ui_up") else 1), TAB_TEXTS.size()))
	elif event.is_action_pressed(PadNav.TAB_PREV) or event.is_action_pressed(PadNav.TAB_NEXT):
		get_viewport().set_input_as_handled()
		show_tab(posmod(int(tab) + (-1 if event.is_action_pressed(PadNav.TAB_PREV) else 1), TAB_TEXTS.size()))


# ---------------------------------------------------------------- Dev (snaps)

## tools/snap.sh ... --title=garage: --xp= (lifetime XP, unlocks follow), --tab=car|paint|
## rims, --pick=<item id> (a tap on it: select, or preview when locked).
func snap_setup(args: Dictionary) -> void:
	if args.has("xp"):
		profile.stats[MetaProfile.XP] = int(args["xp"])
		profile.refresh_unlocks()
	var t := TAB_TEXTS.find(str(args.get("tab", "car")).to_upper())
	show_tab(maxi(t, 0))
	if args.has("pick"):
		pick(StringName(str(args["pick"])))
	finish_animations()


# ---------------------------------------------------------------- Layout

## The item list's width at the current text size.
func list_width() -> float:
	return progression.garage_list_width_px * lerpf(1.0, style.ts, LIST_GROW)


func _layout() -> void:
	if style == null or progression == null:
		return
	var m := margin()
	var g := tuning.spacing_grid_px
	var a := safe.grow(-m)
	var th := tuning.touch_target_px
	dim.position = Vector2.ZERO
	dim.size = full.size
	# Top row: GARAGE, the driver level, DONE.
	var ts := title_text.get_combined_minimum_size()
	title_text.position = a.position
	title_text.size = ts
	var dw := maxf(tuning.menu_button_width_px * DONE_WIDTH, SocialUi.button_width(done_button, tuning))
	done_button.size = Vector2(dw, th)
	done_button.position = Vector2(a.end.x - dw, a.position.y + (ts.y - th) * 0.5)
	var lw := progression.garage_level_width_px * style.ts
	var lx := done_button.position.x - g * 3.0 - lw
	var ls := level_text.get_combined_minimum_size()
	var xs := xp_text.get_combined_minimum_size()
	var bar_h := progression.garage_xp_bar_px
	var block_h := ls.y + g + bar_h + g * 0.5 + xs.y
	var ly := a.position.y + maxf((ts.y - block_h) * 0.5, 0.0)
	level_text.position = Vector2(lx, ly)
	level_text.size = Vector2(lw, ls.y)
	xp_bar.position = Vector2(lx, ly + ls.y + g * 0.5)
	xp_bar.size = Vector2(lw, bar_h)
	xp_text.position = Vector2(lx, xp_bar.position.y + bar_h + g * 0.5)
	xp_text.size = Vector2(lw, xs.y)
	# The tabs and the list on the left.
	var lwid := list_width()
	var top := a.position.y + maxf(ts.y, th) + g * 2.0
	var tw := (lwid - g * float(TAB_TEXTS.size() - 1)) / float(TAB_TEXTS.size())
	for i in tab_buttons.size():
		tab_buttons[i].position = Vector2(a.position.x + float(i) * (tw + g), top)
		tab_buttons[i].size = Vector2(tw, th)
	var list_top := top + th + g * 2.0
	_grid(car_items, progression.garage_car_columns, Vector2(a.position.x, list_top), lwid, th, g)
	_grid(paint_items, progression.garage_paint_columns, Vector2(a.position.x, list_top), lwid, th, g)
	_grid(rim_items, progression.garage_rim_columns, Vector2(a.position.x, list_top), lwid, th, g)
	for b in paint_items:
		b.swatch_frac = clampf(progression.garage_swatch_frac, 0.0,
				maxf((b.size.x - b.label_end() - g * 3.0) / maxf(b.size.x, 1.0), 0.0))
	# The info under the turntable, left-anchored in its column.
	var col_x := a.position.x + lwid + g * 3.0
	var col_w := a.end.x - col_x
	var stats_s := stats_text.get_combined_minimum_size()
	var note_s := note_text.get_combined_minimum_size()
	var name_s := name_text.get_combined_minimum_size()
	var y := a.end.y - stats_s.y
	stats_text.position = Vector2(col_x, y)
	stats_text.size = Vector2(maxf(stats_s.x, 0.0), stats_s.y)
	y -= note_s.y
	SocialUi.fit_text(note_text, note_text.text, col_w)
	note_text.position = Vector2(col_x, y)
	note_text.size = note_text.get_combined_minimum_size()
	y -= name_s.y
	name_text.position = Vector2(col_x, y)
	name_text.size = name_s
	# The turntable fills the column from the tabs down to the screen's edges (a 3D view,
	# not a control); the car's name and stats sit over its lower part.
	turntable.position = Vector2(col_x - g * 2.0, top)
	turntable.size = Vector2(full.size.x - turntable.position.x, maxf(full.size.y - top, th))


func _grid(items: Array[GarageItemButton], cols: int, at: Vector2, width: float, h: float, g: float) -> void:
	var c := maxi(cols, 1)
	var w := (width - g * float(c - 1)) / float(c)
	for i in items.size():
		@warning_ignore("integer_division")
		var row := i / c
		items[i].position = at + Vector2(float(i % c) * (w + g), float(row) * (h + g))
		items[i].size = Vector2(w, h)


## DONE's share of the menu width; how much the list grows with the text size.
const DONE_WIDTH := 0.6   # lint: allow-number layout proportion
const LIST_GROW := 0.6   # lint: allow-number layout proportion
