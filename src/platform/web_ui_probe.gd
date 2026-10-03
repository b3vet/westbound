class_name WebUiProbe
extends Node
## Where the menu buttons are, for the web smoke test (WP9.7). Spec: Platform (web
## export second). docs/WEB.md → Landscape only.
##
## Only with `?probe=ui` on the web (tools/web_smoke/smoke.mjs --tap-play adds it):
## WebAudio adds one. Every PERIOD_S it lists the visible menu buttons and, when the
## list changed, prints one console line per button:
##   wbui: button <x> <y> <w> <h> canvas <W> <H> <TEXT>
## (canvas px, the root viewport's visible rect). The smoke test turns a button's
## centre into a page tap, through the shell's rotation when the page is rotated, and
## so checks the whole input path. After the list, the button the gamepad's focus shows
## on (PadNav), if any (the --gamepad smoke):
##   wbui: focus <TEXT>
## Reads the tree only; never drives anything.

const PARAM_JS := "/[?&]probe=ui(&|$)/.test(window.location.search)"
## Probe period (smoke instrumentation, not gameplay tuning).
const PERIOD_S := 0.25

var _left: float = 0.0
var _last: String = ""


## True on the web with `?probe=ui`.
static func wanted() -> bool:
	return OS.has_feature("web") and bool(JavaScriptBridge.eval(PARAM_JS, true))


func _init() -> void:
	name = "WebUiProbe"
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(dt: float) -> void:
	_left -= dt
	if _left > 0.0:
		return
	_left = PERIOD_S
	var lines := report(get_tree().root, get_viewport().get_visible_rect().size)
	var text := "\n".join(lines)
	if text != _last:
		_last = text
		for line in lines:
			print(line)


## One line per visible ScreenButton under `root` (tree order).
static func report(root: Node, canvas: Vector2) -> PackedStringArray:
	var out := PackedStringArray()
	_collect(root, canvas, out)
	var f := root.get_viewport().gui_get_focus_owner() as ScreenButton if root.is_inside_tree() else null
	if f != null and f.focus_shown():
		out.append("wbui: focus %s" % f.text)
	return out


static func _collect(n: Node, canvas: Vector2, out: PackedStringArray) -> void:
	if n is ScreenButton:
		var b := n as ScreenButton
		if b.is_visible_in_tree() and not b.text.is_empty():
			var r := b.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, b.size)
			out.append("wbui: button %d %d %d %d canvas %d %d %s" % [roundi(r.position.x), roundi(r.position.y),
					roundi(r.size.x), roundi(r.size.y), roundi(canvas.x), roundi(canvas.y), b.text])
	for ch in n.get_children():
		_collect(ch, canvas, out)
