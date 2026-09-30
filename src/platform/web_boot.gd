class_name WebBoot
extends RefCounted
## Boot milestones for the web build (WP9.2): load time is measured from the page's
## side. Spec: Platform (web export second); Implementation order, Phase 9 ("web build
## polish ... load time"). docs/WEB.md → Measuring.
##
## mark(name) stores performance.now() in `window.wbBoot[name]`, dispatches a
## `wb-boot` event on window (detail: the name; the custom shell hides its loading
## screen on "title" or "run") and prints "web boot: <name> <ms> ms" for the smoke
## harness (tools/web_smoke/smoke.mjs reads the console). Each name is marked once per
## page. Off the web it does nothing.

const TITLE := "title"
const RUN := "run"
## WP9.7: the first run started from the title (PLAY, or the first-run chooser after it):
## the smoke test's proof that a tap on PLAY reached the game.
const START := "start"

static var _marked: Dictionary = {}


## Records milestone `name` once. Returns the page time in ms, or -1 (off the web, or
## already marked).
static func mark(milestone: String) -> float:
	if not OS.has_feature("web") or _marked.has(milestone):
		return -1.0
	_marked[milestone] = true
	var js := "(function (n) { var t = performance.now(); window.wbBoot = window.wbBoot || {};" \
			+ " window.wbBoot[n] = t; try { window.dispatchEvent(new CustomEvent('wb-boot', { detail: n })); }" \
			+ " catch (e) { } return t; })(%s)" % JSON.stringify(milestone)
	var ms := float(JavaScriptBridge.eval(js, true))
	print("web boot: %s %d ms" % [milestone, roundi(ms)])
	return ms


## True once `milestone` was marked on this page.
static func is_marked(milestone: String) -> bool:
	return _marked.has(milestone)
