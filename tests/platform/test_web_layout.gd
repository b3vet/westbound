extends WBTest
## The web shell's landscape-only layout (WP9.7). Spec: Platform (web export second);
## UI → Safe areas. docs/WEB.md → Landscape only.
##
## The rotation itself is page JavaScript (platform/web/shell.html): its pure math (the
## rotation decision, client → box coordinates and back, movements, inset mapping, and
## what Godot's computePosition then makes of a rewritten event) is tested in node by
## tools/web_smoke/layout_test.mjs, which this test runs when node is installed; the
## browser path by tools/web_smoke/smoke.mjs --portrait / --landscape. Here: the shell
## has the pieces the game relies on, and the game side off the web is inert.

const SHELL := "res://platform/web/shell.html"
const LAYOUT_TEST := "tools/web_smoke/layout_test.mjs"

var html: String


func before_all() -> void:
	html = FileAccess.get_file_as_string(SHELL)


func test_shell_rotates_and_remaps_before_the_engine() -> void:
	check(html.contains("window.wbLayout = L"), "publishes window.wbLayout")
	for key: String in ["rotated", "phone", "width", "height", "il", "it", "ir", "ib"]:
		check(html.contains(key + ":"), "wbLayout has %s" % key)
	check(html.contains("GODOT_CONFIG.canvasResizePolicy = 0"), "the shell sizes the canvas (policy None)")
	check(html.contains("<div id=\"wb-rotor\">\n<canvas id=\"canvas\">"), "the canvas is inside the rotated box")
	check(html.contains("canvas.getBoundingClientRect = function"), "the engine reads the box's own rect")
	check(html.contains("{ capture: true, passive: true }"), "capture listeners (before the engine's own)")
	for ev: String in ["'touchstart'", "'touchmove'", "'touchend'", "'touchcancel'", "'mousedown'", "'mouseup'",
			"'pointermove'"]:
		check(html.contains(ev), "remaps %s" % ev)
	check(html.contains("define(e, 'changedTouches', out)"), "touches keep their browser ids (TouchSlots maps them)")
	check(html.contains("env(safe-area-inset-top"), "reads the page's safe-area insets")
	check(html.contains("viewport-fit=cover"), "the page covers the cutout (insets are reported)")
	var math_at := html.find("// <wb-layout-math>")
	check(math_at >= 0 and html.find("// </wb-layout-math>") > math_at, "the pure math block for the node test")
	# The layout script runs before the engine script.
	lt(html.find("window.wbLayout = L"), html.find("<script src=\"$GODOT_URL"), "layout before the engine")


func test_shell_layout_math_in_node() -> void:
	var node := _node()
	if node.is_empty():
		print("    (node not installed: tools/web_smoke/layout_test.mjs skipped; the web smoke runs it)")
		return
	var out: Array = []
	var code := OS.execute(node, [ProjectSettings.globalize_path("res://" + LAYOUT_TEST)], out, true)
	eq(code, 0, "layout_test.mjs: %s" % "".join(out).strip_edges())


func test_game_side_is_inert_off_the_web() -> void:
	check(not WebLayout.available(), "no page")
	check(not WebLayout.rotated())
	eq(WebLayout.page_insets_css(), Vector4.ZERO)
	check(not WebUiProbe.wanted(), "no UI probe off the web")
	var src := WebMotionSource.new()
	eq(src.screen_rotation_deg(), 0, "no page angle off the web")


func test_ui_probe_lists_visible_buttons() -> void:
	var root := Control.new()
	tree.root.add_child(root)
	var style := HudStyle.new()
	var tuning := Tuning.load_default().hud
	style.setup(UiTheme.load_theme(), tuning, 1.0)
	var play := ScreenButton.make("PLAY", ScreenButton.Kind.PRIMARY, 24)
	play.setup(style)
	root.add_child(play)
	play.position = Vector2(100.0, 400.0)
	play.size = Vector2(300.0, 80.0)
	var hidden := ScreenButton.make("HIDDEN", ScreenButton.Kind.NORMAL, 24)
	hidden.setup(style)
	root.add_child(hidden)
	hidden.visible = false
	var lines := WebUiProbe.report(root, Vector2(1280.0, 752.0))
	eq(lines.size(), 1, "visible buttons only")
	eq(lines[0], "wbui: button 100 400 300 80 canvas 1280 752 PLAY", "canvas px and the label")
	root.free()


static func _node() -> String:
	for p: String in ["/opt/node22/bin/node", "/usr/local/bin/node", "/usr/bin/node"]:
		if FileAccess.file_exists(p):
			return p
	var out: Array = []
	if OS.execute("sh", ["-c", "command -v node"], out) == 0 and not out.is_empty():
		return str(out[0]).strip_edges()
	return ""
