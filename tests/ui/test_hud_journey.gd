extends WBTest
## The JOURNEY COMPLETE banner (WP6.5). Spec: The journey goal ("'Journey complete' is
## recorded"; the road goes on), UI → Screens (toasts never pause play), HUD layout (the
## middle third stays clear), Accessibility (text size). docs/HUD.md.

const HUD_SCENE := "res://src/ui/hud/hud.tscn"
const DT := 1.0 / 60.0
const CANVASES: Array[Vector2] = [Vector2(1280.0, 720.0), Vector2(1361.0, 720.0), Vector2(1560.0, 720.0)]
## The top-centre readouts end above this share of the height (test_hud_layout.gd).
const MIDDLE_TOP_FRAC := 0.45

var t: Tuning
var hud: Hud


func before_all() -> void:
	t = Tuning.load_default()


func before_each() -> void:
	Settings.reset_to_defaults()
	hud = (load(HUD_SCENE) as PackedScene).instantiate() as Hud
	hud.auto_process = false
	var full := Rect2(Vector2.ZERO, CANVASES[0])
	hud.set_screen(full, full)
	tree.root.add_child(hud)
	var feed := HudFeed.new()
	feed.top_speed_mps = Units.kmh_to_mps(270.0)
	hud.bind(feed)
	hud.advance(DT)


func after_each() -> void:
	if hud != null:
		hud.free()
		hud = null
	Settings.reset_to_defaults()


func _run(seconds: float) -> void:
	for i in ceili(seconds / DT):
		hud.advance(DT)


func test_banner_shows_the_journey_bonus_and_fades() -> void:
	Events.bonus_awarded.emit(Run.BONUS_JOURNEY, t.legs.journey_bonus_points, 123_456)
	Events.journey_complete.emit()
	hud.advance(DT)
	check(hud.journey_toast_visible(), "shown")
	var lines := hud.journey_toast_lines()
	eq(lines[0], "JOURNEY COMPLETE")
	check(lines[1].contains(HudFormat.thousands(t.legs.journey_bonus_points)), "names the bonus: %s" % lines[1])
	check(lines[1].contains("COAST"), "and the coast")
	_run(t.hud.journey_toast_s * 0.5)
	check(hud.journey_toast_visible(), "holds")
	_run(t.hud.journey_toast_s * 0.6)
	check(not hud.journey_toast_visible(), "gone after journey_toast_s")


func test_banner_stays_out_of_the_middle_and_fits() -> void:
	for canvas in CANVASES:
		for scale in t.hud.text_scales:
			Settings.set_value(&"text_scale", scale)
			var full := Rect2(Vector2.ZERO, canvas)
			hud.set_screen(full, full)
			hud.advance(DT)
			Events.journey_complete.emit()
			_run(t.hud.journey_toast_in_s + DT * 2.0)
			var r := hud.journey_toast_rect()
			check(full.encloses(r), "on screen at %s x%.2f" % [canvas, scale])
			check(r.end.y <= canvas.y * MIDDLE_TOP_FRAC, "above the middle third at %s x%.2f" % [canvas, scale])
			var toast := hud.get_node(^"Root/JourneyToast") as HudJourneyToast
			check(toast.fits_title(), "the title fits at %s x%.2f" % [canvas, scale])
			_run(t.hud.journey_toast_s)


func test_a_new_run_dismisses_it() -> void:
	Events.journey_complete.emit()
	hud.advance(DT)
	Events.run_started.emit(RunContext.MODE_JOURNEY, 1)
	hud.advance(DT)
	check(not hud.journey_toast_visible(), "dismissed on a new run")
