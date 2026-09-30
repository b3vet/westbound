extends WBTest
## WP8.2: the garage screen over the title (TitleScreens): GARAGE and DONE, the tabs, a
## tap on an unlocked item selects and saves it, a tap on a locked item (or a placeholder
## slot) previews it and never selects it, the keys, the turntable (on only while open,
## the look it shows, a drag spins it, no rebuild for a paint change), and nothing drawn
## once closed. Taps are touches with iOS-style ids (emulated mouse events). Spec: UI →
## Screens (Garage); Garage and progression. docs/GARAGE.md.

const SCREEN := Rect2(0.0, 0.0, 1280.0, 720.0)
const IOS_ID := 1_893_457_201

var t: Tuning
var cat: GarageCatalog
var _nodes: Array[Node] = []
var _saved: Dictionary
var _closed: int = 0


func before_all() -> void:
	t = Tuning.load_default()
	cat = Garage.catalog()


func before_each() -> void:
	Settings.reset_to_defaults()
	_saved = Save.data.duplicate(true)
	for k: String in [Garage.SECTION_STATS, Garage.SECTION_UNLOCKS, Garage.SECTION_GARAGE]:
		Save.data.erase(k)
	Save.section(Garage.SECTION_STATS)[MetaProfile.BACKFILLED] = true   # a fresh profile, whatever bests other tests left
	_closed = 0


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	Save.data = _saved
	Save.dirty = false
	Settings.reset_to_defaults()


func _title() -> TitleScreens:
	var ts := TitleScreens.new()
	ts.persist_settings = false
	tree.root.add_child(ts)
	_nodes.append(ts)
	ts.set_screen(SCREEN, SCREEN)
	ts.garage_closed.connect(func() -> void: _closed += 1)
	ts.show_state(Game.MENU)
	ts.finish_animations()
	return ts


func _garage(ts: TitleScreens) -> GarageScreen:
	_tap(ts.title.garage_button)
	ts.finish_animations()
	return ts.garage


func _set_level(level: int) -> void:
	var p := Garage.profile()
	p.stats[MetaProfile.XP] = Progression.xp_to_reach(level, t.progression)
	p.refresh_unlocks()


func _tap(c: Control) -> void:
	var p := tree.root.get_final_transform() * c.get_global_rect().get_center()
	for down: bool in [true, false]:
		var ev := InputEventScreenTouch.new()
		ev.index = IOS_ID
		ev.position = p
		ev.pressed = down
		Input.parse_input_event(ev)
		Input.flush_buffered_events()


func _key(action: StringName) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


func _slot_of(kind: StringName) -> GarageSlot:
	for s in cat.slots:
		if s.unlock == kind:
			return s
	return null


# ---------------------------------------------------------------- Open and close

func test_garage_opens_from_the_title_and_done_comes_back() -> void:
	var ts := _title()
	check(ts.garage == null, "nothing built before the first GARAGE")
	var g := _garage(ts)
	if not check(g != null and g.visible, "GARAGE opens the garage"):
		return
	check(not ts.title.visible, "the menu steps aside")
	check(ts.is_open())
	check(g.turntable.active, "the turntable renders while open")
	eq(g.turntable.viewport.render_target_update_mode, SubViewport.UPDATE_ALWAYS)
	eq(g.tab, GarageScreen.Tab.CAR, "on the CAR tab")
	eq(g.turntable.car, cat.slots[0].car(), "the selected (start) car on the turntable")
	eq(g.note_text.text, GarageScreen.TEXT_SELECTED)
	gt(g.xp_text.text.length(), 0, "the driver level's XP")
	eq(g.level_text.text, GarageScreen.TEXT_LEVEL % 1)
	_tap(g.done_button)
	check(not g.visible and ts.title.visible, "DONE: the title")
	check(not g.turntable.active, "the turntable stops")
	eq(g.turntable.viewport.render_target_update_mode, SubViewport.UPDATE_DISABLED, "and renders nothing")
	eq(_closed, 1, "garage_closed tells the run")
	ts.show_state(Game.COUNTDOWN)
	eq(ts.visible_item_count(), 0, "nothing drawn once a run starts")


func test_tabs_show_their_items() -> void:
	var g := _garage(_title())
	eq(g.car_items.size(), t.progression.roster_size, "8 roster slots")
	eq(g.paint_items.size(), cat.paints.size())
	eq(g.rim_items.size(), cat.rims.size())
	var lists: Array = [g.car_items, g.paint_items, g.rim_items]
	for i in g.tab_buttons.size():
		_tap(g.tab_buttons[i])
		eq(int(g.tab), i)
		check(g.tab_buttons[i].selected, "tab %d selected" % i)
		for k in lists.size():
			for b: GarageItemButton in lists[k]:
				eq(b.visible, k == i, "%s shows only on its tab" % b.name)
	for b in g.car_items:
		ge(b.size.y, t.hud.touch_target_px, "touch target")


func test_placeholders_are_clearly_marked() -> void:
	var g := _garage(_title())
	for i in cat.slots.size():
		var s := cat.slots[i]
		if s.has_car():
			eq(g.car_items[i].text, s.car().display_name.to_upper())
		else:
			eq(g.car_items[i].text, GarageCatalog.TEXT_COMING_SOON, "slot %d is a marked placeholder" % i)
			check(g.car_items[i].locked)
			check(not g.car_items[i].note.is_empty(), "with its unlock rule")
	var coast := _slot_of(GarageSlot.UNLOCK_COAST)
	_tap(g.item(coast.id))
	check(not g.turntable.has_car(), "a placeholder shows an empty disc")
	eq(g.name_text.text, GarageCatalog.TEXT_COMING_SOON)
	check(g.note_text.text.contains(GarageScreen.TEXT_UNLOCK_COAST), "and what unlocks it")
	eq(Garage.profile().selected_slot(), cat.slots[0], "never selected")


# ---------------------------------------------------------------- Select and preview

func test_an_unlocked_item_selects_and_saves() -> void:
	_set_level(t.progression.max_level)
	var g := _garage(_title())
	var viper := cat.slot(&"night_viper")
	_tap(g.item(viper.id))
	eq(Garage.profile().selected_slot(), viper, "selected")
	eq(Garage.selected_car_path(), viper.car_path, "the next run's car")
	check(Save.dirty, "saved at the end of the frame")
	check(g.item(viper.id).selected)
	eq(g.item(viper.id).note, GarageScreen.TEXT_SELECTED)
	eq(g.turntable.car, viper.car())
	_tap(g.tab_buttons[GarageScreen.Tab.PAINT])
	var paint := cat.paints[cat.paints.size() - 1]
	_tap(g.item(paint.id))
	eq(Garage.profile().paint_for(viper.id), paint, "the paint is the selected car's")
	check(g.turntable.look.paint.is_equal_approx(paint.color), "the turntable wears it")
	_tap(g.tab_buttons[GarageScreen.Tab.RIMS])
	var rim := cat.rims[cat.rims.size() - 1]
	var builds := g.turntable.builds
	_tap(g.item(rim.id))
	eq(Garage.profile().rim_for(viper.id), rim)
	eq(g.turntable.look.rim, rim)
	eq(g.turntable.builds, builds + 1, "new rims rebuild the model once")
	var look := Garage.selected_look(viper.car())
	check(look.paint.is_equal_approx(paint.color) and look.rim == rim, "the run's look")
	_tap(g.tab_buttons[GarageScreen.Tab.PAINT])
	builds = g.turntable.builds
	_tap(g.item(cat.paints[1].id))
	eq(g.turntable.builds, builds, "a paint change recolours in place")


func test_a_locked_item_previews_but_is_never_selected() -> void:
	var g := _garage(_title())
	var start := cat.slots[0]
	var viper := cat.slot(&"night_viper")
	check(g.item(viper.id).locked, "locked at level 1")
	_tap(g.item(viper.id))
	eq(Garage.profile().selected_slot(), start, "a locked car is not selected")
	eq(g.turntable.car, viper.car(), "but it shows on the turntable")
	eq(g.note_text.text, GarageScreen.TEXT_LOCKED % (GarageScreen.TEXT_UNLOCK_LEVEL % viper.unlock_level))
	check(g.item(start.id).selected, "the selection stays marked")
	var leg := _slot_of(GarageSlot.UNLOCK_LEG)
	_tap(g.item(leg.id))
	check(g.note_text.text.contains(GarageScreen.TEXT_UNLOCK_LEG % t.progression.unlock_leg_milestone))
	_tap(g.tab_buttons[GarageScreen.Tab.PAINT])
	eq(g.turntable.car, start.car(), "a new tab shows the selected car again")
	var locked: PaintOption = null
	for p in cat.paints:
		if p.unlock_level > 1:
			locked = p
			break
	_tap(g.item(locked.id))
	check(Garage.profile().paint_for(start.id).factory, "a locked paint is not selected")
	check(g.turntable.look.paint.is_equal_approx(locked.color), "but previewed")
	check(g.note_text.text.begins_with("PREVIEW"))
	_tap(g.tab_buttons[GarageScreen.Tab.RIMS])
	var rim := cat.rims[cat.rims.size() - 1]
	_tap(g.item(rim.id))
	check(Garage.profile().rim_for(start.id).model_default, "a locked rim is not selected")
	eq(g.turntable.look.rim, rim)
	_tap(g.done_button)
	eq(Save.section(Garage.SECTION_GARAGE), {}, "previews write nothing")
	var g2 := _garage(_title())
	eq(g2.turntable.car, start.car(), "reopened: the selection, not the preview")


func test_keys() -> void:
	_set_level(t.progression.max_level)
	var ts := _title()
	var g := _garage(ts)
	_key(&"ui_right")
	eq(Garage.profile().selected_slot(), cat.slots[1], "Right: the next car (selected: unlocked)")
	_key(&"ui_left")
	eq(Garage.profile().selected_slot(), cat.slots[0], "Left: back")
	_key(&"ui_down")
	eq(g.tab, GarageScreen.Tab.PAINT, "Down: the next tab")
	_key(&"ui_right")
	eq(Garage.profile().paint_for(cat.slots[0].id), cat.paints[1], "Right on PAINT")
	_key(&"ui_up")
	_key(&"ui_up")
	eq(g.tab, GarageScreen.Tab.RIMS, "Up wraps")
	_key(&"ui_cancel")
	check(not g.visible and ts.title.visible, "Esc: DONE")
	g = _garage(ts)
	_key(&"ui_accept")
	check(not g.visible and ts.title.visible, "Enter: DONE")
	eq(_closed, 2)


# ---------------------------------------------------------------- Turntable

func test_turntable_spins_and_drags() -> void:
	var g := _garage(_title())
	var tt := g.turntable
	var y0 := tt.yaw
	tt._process(1.0)
	near(angle_difference(y0, tt.yaw), deg_to_rad(t.progression.turntable_spin_deg_s), 1e-4, "the idle spin")
	var ev := InputEventMouseMotion.new()
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	ev.relative = Vector2(100.0, 0.0)
	var y1 := tt.yaw
	tt._gui_input(ev)
	near(angle_difference(y1, tt.yaw), deg_to_rad(t.progression.turntable_drag_deg_per_px * 100.0), 1e-4, "a drag turns it")
	near(tt.pivot.rotation.y, tt.yaw, 1e-5)
	tt.still = true
	y1 = tt.yaw
	tt._process(1.0)
	eq(tt.yaw, y1, "reduced motion: no idle spin")


func test_turntable_uses_the_project_shaders_only() -> void:
	var g := _garage(_title())
	var bad := _bad_nodes(g.turntable.viewport)
	eq(bad, PackedStringArray(), "no lights, no environment, no StandardMaterial3D")
	check(g.turntable.viewport.own_world_3d and g.turntable.viewport.transparent_bg,
			"its own world over the live title, transparent")
	var mat := g.turntable.disc.mesh.surface_get_material(0) as ShaderMaterial
	check(mat != null and mat.shader == CarModel.VEHICLE_SHADER, "the disc is the vehicle shader (the live sky's lighting)")


func _bad_nodes(n: Node) -> PackedStringArray:
	var out := PackedStringArray()
	if n is Light3D or n is WorldEnvironment:
		out.append(n.name)
	if n is GeometryInstance3D:
		var gi := n as GeometryInstance3D
		if gi.material_override is StandardMaterial3D:
			out.append(n.name)
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mesh := (n as MeshInstance3D).mesh
			for s in mesh.get_surface_count():
				if mesh.surface_get_material(s) is StandardMaterial3D or (n as MeshInstance3D).get_active_material(s) is StandardMaterial3D:
					out.append("%s/%d" % [n.name, s])
	for c in n.get_children():
		out.append_array(_bad_nodes(c))
	return out
