class_name WebAudioBridge
extends RefCounted
## The page side of the web audio unlock (WP9.2). Spec: Platform (web export second);
## Audio. docs/WEB.md → Audio unlock.
##
## Browsers start a page's AudioContext suspended until a user gesture (Chrome's
## autoplay policy, iOS Safari always). Godot 4.7's web engine calls resume() from its
## own mouse, touch and key callbacks, which run inside the browser's event dispatch
## in the single-threaded build, so the first tap, click or key already unlocks
## (verified in headless Chromium, docs/WEB.md). This bridge adds what the engine
## does not have:
##
## - It finds the engine's AudioContext: `window.wbAudioCtx` (recorded by the custom
##   web shell, platform/web/shell.html) or the engine's own `GodotAudio.ctx`, reached
##   by evaluating in the engine's scope (JavaScriptBridge.eval without the global
##   context). Neither found: the state falls back to navigator.userActivation.
## - Capture-phase listeners on `window` for the activating events (pointerup,
##   touchend, mousedown, keydown, click) call resume() and start a one-sample silent
##   buffer inside the gesture (older iOS unlocks only on a sound started in a
##   gesture). They cover gestures the engine never sees: a tap on an HTML overlay, or
##   a key while the canvas does not have focus. They only act when the page's user
##   activation is live, so the browser never logs "not allowed to start".
## - state(): the context state for WebAudio to poll: suspended | running |
##   interrupted (iOS) | closed, or "" when nothing is known.
##
## Off the web every method is inert. Tests use a subclass with a scripted state.

const JS_NAME := "wbAudio"
## Installed once per page, evaluated in the engine's scope (see above). ES5.
const JS_SOURCE := """
(function () {
	if (window.wbAudio) { return; }
	var ctx = window.wbAudioCtx || null;
	var source = ctx ? 'shell' : 'none';
	if (!ctx) {
		try {
			if (typeof GodotAudio !== 'undefined' && GodotAudio.ctx) { ctx = GodotAudio.ctx; source = 'engine'; }
		} catch (e) { ctx = null; }
	}
	var a = { ctx: ctx, source: source, gestures: 0, resumes: 0 };
	var ua = navigator.userActivation;
	function silent() {
		try {
			var s = ctx.createBufferSource();
			s.buffer = ctx.createBuffer(1, 1, ctx.sampleRate);
			s.connect(ctx.destination);
			s.start(0);
		} catch (e) { }
	}
	function onGesture() {
		a.gestures += 1;
		if (!ctx || ctx.state === 'running' || ctx.state === 'closed') { return; }
		if (ua && !ua.isActive) { return; }
		a.resumes += 1;
		try {
			var p = ctx.resume();
			if (p && p.catch) { p.catch(function () { }); }
		} catch (e) { }
		silent();
	}
	var kinds = ['pointerup', 'touchend', 'mousedown', 'keydown', 'click'];
	for (var i = 0; i < kinds.length; i++) {
		window.addEventListener(kinds[i], onGesture, true);
	}
	a.state = function () {
		if (ctx) { return String(ctx.state); }
		if (ua) { return ua.hasBeenActive ? 'running' : 'suspended'; }
		return '';
	};
	window.wbAudio = a;
})();
"""

var _js: JavaScriptObject


## Installs the page side once. False off the web (or if the page refused it).
func install() -> bool:
	if _js != null:
		return true
	if not OS.has_feature("web"):
		return false
	JavaScriptBridge.eval(JS_SOURCE, false)
	_js = JavaScriptBridge.get_interface(JS_NAME)
	return _js != null


## The AudioContext state: suspended | running | interrupted | closed, "" if unknown.
func state() -> String:
	if _js == null:
		return ""
	return str(_js.call("state"))


## Where the context came from: shell | engine | none (the dev report and docs).
func source() -> String:
	if _js == null:
		return "none"
	return str(_js.get("source"))
