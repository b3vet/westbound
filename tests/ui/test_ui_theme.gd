extends WBTest
## The design-system theme. Spec: UI, HUD and design system → Design system (faceted
## panels: StyleBoxFlat corner_radius = bevel, corner_detail = 1, 13 px panels, 7 px
## small controls; 1.5 px neon edge; the color table; Chakra Petch 600/700 bundled;
## one Theme resource) and the speed-tilt shader. Plan WP4.3; CONTRACTS §14.

const EPS := 1e-4
const HEX := {
	UiTheme.C_INK: "#0b1020",
	UiTheme.C_PANEL: "#111a30",
	UiTheme.C_TEXT: "#f4f7ff",
	UiTheme.C_MUTED: "#8a93ad",
	UiTheme.C_GOLD: "#ffd24a",
	UiTheme.C_HOT: "#ff5a4d",
}
const LICENSES := "res://assets/LICENSES.md"
const OFL := "res://assets/fonts/OFL.txt"
const TILT_SHADER := "res://src/ui/theme/speed_tilt.gdshader"

var hud: HudTuning
var saved: Theme


func before_all() -> void:
	hud = Tuning.load_default().hud
	saved = load(UiTheme.PATH) as Theme


func test_theme_file_exists_and_loads() -> void:
	check(ResourceLoader.exists(UiTheme.PATH), "theme.tres exists")
	check(saved != null, "theme.tres loads as a Theme")
	check(UiTheme.load_theme() != null)


func test_colors_are_the_spec_table() -> void:
	if not check(saved != null):
		return
	for key: StringName in HEX:
		eq(saved.get_color(key, UiTheme.TYPE).to_html(false), Color(String(HEX[key])).to_html(false), String(key))
	check(saved.has_color(UiTheme.C_ACCENT, UiTheme.TYPE), "accent color present")


func test_bevels_and_border_match_tuning() -> void:
	if not check(saved != null):
		return
	eq(hud.panel_bevel_px, 13.0, "spec panel bevel")
	eq(hud.control_bevel_px, 7.0, "spec control bevel")
	eq(hud.neon_border_px, 1.5, "spec neon edge")
	eq(saved.get_constant(UiTheme.K_PANEL_BEVEL, UiTheme.TYPE), roundi(hud.panel_bevel_px))
	eq(saved.get_constant(UiTheme.K_CONTROL_BEVEL, UiTheme.TYPE), roundi(hud.control_bevel_px))
	eq(saved.get_constant(UiTheme.K_BORDER, UiTheme.TYPE), UiTheme.border_px(hud))
	_check_box(saved.get_stylebox(UiTheme.B_PANEL, UiTheme.TYPE), hud.panel_bevel_px, "panel")
	_check_box(saved.get_stylebox(UiTheme.B_CONTROL, UiTheme.TYPE), hud.control_bevel_px, "control")
	_check_box(saved.get_stylebox(&"panel", &"PanelContainer"), hud.panel_bevel_px, "PanelContainer")
	for state: StringName in [&"normal", &"hover", &"pressed", &"focus", &"disabled"]:
		_check_box(saved.get_stylebox(state, &"Button"), hud.control_bevel_px, "Button " + state)


func _check_box(sb: StyleBox, bevel: float, what: String) -> void:
	var b := sb as StyleBoxFlat
	if not check(b != null, what + " is a StyleBoxFlat"):
		return
	eq(b.corner_detail, 1, what + ": corner_detail 1 = straight chamfers")
	eq(b.corner_radius_top_left, roundi(bevel), what)
	eq(b.corner_radius_top_right, roundi(bevel), what)
	eq(b.corner_radius_bottom_left, roundi(bevel), what)
	eq(b.corner_radius_bottom_right, roundi(bevel), what)
	eq(b.border_width_left, UiTheme.border_px(hud), what + " border")
	eq(b.border_width_top, UiTheme.border_px(hud), what + " border")


func test_fonts_are_chakra_petch_with_tracking_and_sizes() -> void:
	if not check(saved != null):
		return
	var display := saved.get_font(UiTheme.F_DISPLAY, UiTheme.TYPE) as FontVariation
	var label := saved.get_font(UiTheme.F_LABEL, UiTheme.TYPE) as FontVariation
	var body := saved.get_font(UiTheme.F_BODY, UiTheme.TYPE) as FontVariation
	if not (check(display != null) and check(label != null) and check(body != null)):
		return
	eq(display.base_font.resource_path, UiTheme.FONT_BOLD_PATH, "display = Chakra Petch 700")
	eq(label.base_font.resource_path, UiTheme.FONT_SEMIBOLD_PATH, "label = Chakra Petch 600")
	eq(body.base_font.resource_path, UiTheme.FONT_SEMIBOLD_PATH, "body = Chakra Petch 600")
	eq(label.spacing_glyph, hud.label_tracking_px, "tracked labels")
	eq(saved.get_font_size(UiTheme.S_LABEL, UiTheme.TYPE), hud.font_label_px)
	eq(saved.get_font_size(UiTheme.S_SMALL, UiTheme.TYPE), hud.font_small_px)
	eq(saved.get_font_size(UiTheme.S_SCORE, UiTheme.TYPE), hud.font_score_px)
	eq(saved.get_font_size(UiTheme.S_READOUT, UiTheme.TYPE), hud.font_readout_px)
	eq(saved.get_font_size(UiTheme.S_EVENT, UiTheme.TYPE), hud.font_event_px)
	eq(saved.get_font_size(UiTheme.S_SPEED, UiTheme.TYPE), hud.font_speed_px)
	eq(saved.get_font_size(UiTheme.S_BUTTON, UiTheme.TYPE), hud.font_button_px)
	eq(saved.get_font(&"font", &"Button"), label, "buttons use the tracked label font")


func test_font_files_present_and_cover_hud_glyphs() -> void:
	for path: String in [UiTheme.FONT_SEMIBOLD_PATH, UiTheme.FONT_BOLD_PATH]:
		var f := load(path) as FontFile
		if not check(f != null, path):
			continue
		for c in "0123456789,.+-×—%!ABCDEFGHIJKLMNOPQRSTUVWXYZ":
			check(f.has_char(c.unicode_at(0)), "%s has %s" % [path.get_file(), c])
	check(FileAccess.file_exists(OFL), "OFL license text bundled")


func test_fonts_logged_in_licenses() -> void:
	var text := FileAccess.get_file_as_string(LICENSES)
	check(text.contains("ChakraPetch-SemiBold.ttf"), "SemiBold logged")
	check(text.contains("ChakraPetch-Bold.ttf"), "Bold logged")
	check(text.contains("OFL"), "license named")
	check(text.contains("github.com/google/fonts"), "source URL")


## The saved theme is what UiTheme.build() makes now (rerun build_theme.gd otherwise).
func test_saved_theme_is_up_to_date() -> void:
	if not check(saved != null):
		return
	var fresh := UiTheme.build(hud)
	var t := UiTheme.TYPE
	for c in fresh.get_color_list(t):
		eq(saved.get_color(c, t), fresh.get_color(c, t), "color %s (rebuild theme.tres)" % c)
	for s in fresh.get_font_size_list(t):
		eq(saved.get_font_size(s, t), fresh.get_font_size(s, t), "font size %s" % s)
	for k in fresh.get_constant_list(t):
		eq(saved.get_constant(k, t), fresh.get_constant(k, t), "constant %s" % k)
	for type_name: StringName in [t, &"Button"]:
		for name in fresh.get_stylebox_list(type_name):
			var a := saved.get_stylebox(name, type_name) as StyleBoxFlat
			var b := fresh.get_stylebox(name, type_name) as StyleBoxFlat
			if not check(a != null and b != null, "%s/%s" % [type_name, name]):
				continue
			eq(a.bg_color, b.bg_color, "%s/%s fill" % [type_name, name])
			eq(a.border_color, b.border_color, "%s/%s edge" % [type_name, name])
			eq(a.corner_radius_top_left, b.corner_radius_top_left, "%s/%s bevel" % [type_name, name])


func test_apply_accent_retints_accent_items() -> void:
	var th := UiTheme.build(hud)
	UiTheme.apply_accent(th, Color.RED)
	eq(th.get_color(UiTheme.C_ACCENT, UiTheme.TYPE), Color.RED)
	eq((th.get_stylebox(&"hover", &"Button") as StyleBoxFlat).border_color, Color.RED)
	eq((th.get_stylebox(&"pressed", &"Button") as StyleBoxFlat).border_color, Color.RED)
	ne((th.get_stylebox(&"normal", &"Button") as StyleBoxFlat).border_color, Color.RED, "idle edge stays muted")


func test_speed_tilt_shader() -> void:
	var sh := load(TILT_SHADER) as Shader
	if not check(sh != null, "shader loads"):
		return
	eq(sh.get_mode(), Shader.MODE_CANVAS_ITEM)
	var re := RegEx.create_from_string("uniform float tilt_rad = ([-0-9.]+);")
	var m := re.search(sh.code)
	if check(m != null, "tilt_rad uniform declared"):
		near(m.get_string(1).to_float(), hud.speed_tilt_rad(), EPS, "default = hud.speed_tilt_deg")
	near(hud.speed_tilt_deg, -7.0, EPS, "spec: about -7 degrees")
	check(not sh.code.contains("void fragment"), "vertex-only: the renderer's own fragment on both renderers")
