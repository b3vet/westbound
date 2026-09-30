class_name SocialUi
extends RefCounted
## Shared helpers for the social screens (friends, crew, report): fitting names into
## their box, button widths, the text-field look, and the web page's clipboard, share and
## text prompt. Spec: UI, HUD and design system → Design system, Accessibility (text
## size); multiplayer handoff → Client changes (party panel and friends list, crew page).
## WP N9.2; docs/SCREENS.md → Social.
##
## Web glue goes through NetJsBridge (tests swap in a mock): every snippet catches
## everything and answers a plain value, so a browser that refuses (no clipboard
## permission, Safari private mode) never throws into Godot.

const ELLIPSIS := "..."
## Selection highlight opacity in text fields.
const SELECTION_A := 0.35   # lint: allow-number look
## The PRIMARY chevron's room, in cap heights (ScreenButton draws two slanted strokes).
const CHEVRON_CAPS := 2.5   # lint: allow-number glyph proportion

const JS_COPY := "(function(t){try{if(navigator.clipboard&&window.isSecureContext){navigator.clipboard.writeText(t);return 'ok';}}catch(e){}try{var a=document.createElement('textarea');a.value=t;a.setAttribute('readonly','');a.style.position='fixed';a.style.opacity='0';document.body.appendChild(a);a.select();a.setSelectionRange(0,t.length);var r=document.execCommand('copy');document.body.removeChild(a);return r?'ok':'fail';}catch(e){return 'fail';}})(%s)"
const JS_CAN_SHARE := "(function(){try{return !!(navigator.share);}catch(e){return false;}})()"
const JS_SHARE := "(function(t,x){try{navigator.share({title:t,text:x}).catch(function(){});return 'ok';}catch(e){return 'fail';}})(%s,%s)"
const JS_PROMPT := "(function(m,d){try{var v=window.prompt(m,d);return v===null?null:String(v);}catch(e){return null;}})(%s,%s)"
const JS_OK := "ok"


## Sets `t` to `full`, shortened with "..." until it fits `max_w` px.
static func fit_text(t: ScreenText, full: String, max_w: float) -> void:
	t.text = full
	if t.text_width() <= max_w:
		return
	var n := full.length()
	while n > 0:
		n -= 1
		t.text = full.left(n).strip_edges() + ELLIPSIS
		if t.text_width() <= max_w:
			return
	t.text = ""


## The width `b` needs for its label (and note) with the design system's padding, at
## least a square touch target.
static func button_width(b: ScreenButton, t: HudTuning) -> float:
	var pad := t.spacing_grid_px * 2.0
	if b.style == null:
		return t.touch_target_px
	var fs := b.font_px()
	var w := HudDraw.text_width(b.style.label, b.text, fs)
	if not b.note.is_empty():
		w = maxf(w, HudDraw.text_width(b.style.label, b.note, maxi(1, roundi(float(b.style.size_label) * ScreenButton.NOTE_SCALE))))
	w += pad * 2.0 + ScreenButton.PRESS_SHIFT
	if b.kind == ScreenButton.Kind.PRIMARY:
		w += HudDraw.cap_height(fs) * CHEVRON_CAPS
	return ceilf(maxf(w, t.touch_target_px))


## The social screens' text fields: the ProfilePanel's look (faceted box, accent focus).
static func style_edit(e: LineEdit, s: HudStyle, t: HudTuning) -> void:
	if s == null or t == null:
		return
	var border := UiTheme.border_px(t)
	var pad := t.spacing_grid_px * 2.0
	var normal := UiTheme.box(t.control_bevel_px, border, s.panel_fill, s.edge_idle)
	var focus := UiTheme.box(t.control_bevel_px, border, Color(s.ink, 1.0), s.accent)
	var off := UiTheme.box(t.control_bevel_px, border, s.panel_fill, Color(s.muted, SELECTION_A))
	for b: StyleBoxFlat in [normal, focus, off]:
		b.content_margin_left = pad
		b.content_margin_right = pad
	e.add_theme_stylebox_override(&"normal", normal)
	e.add_theme_stylebox_override(&"focus", focus)
	e.add_theme_stylebox_override(&"read_only", off)
	e.add_theme_font_override(&"font", s.body)
	e.add_theme_font_size_override(&"font_size", maxi(1, roundi(float(t.font_screen_button_px) * s.ts)))
	e.add_theme_color_override(&"font_color", s.text)
	e.add_theme_color_override(&"font_placeholder_color", s.muted)
	e.add_theme_color_override(&"font_uneditable_color", s.muted)
	e.add_theme_color_override(&"caret_color", s.accent)
	e.add_theme_color_override(&"selection_color", Color(s.accent, SELECTION_A))


## Puts `text` on the clipboard: the browser's (inside the tap that asked, so iOS allows
## it) on the web, the OS clipboard elsewhere. False when the browser refused.
static func copy_text(bridge: NetJsBridge, text: String) -> bool:
	if bridge != null and bridge.available():
		return _same(bridge.eval(JS_COPY % JSON.stringify(text)), JS_OK)
	DisplayServer.clipboard_set(text)
	return true


## The page can open the system share sheet (mobile browsers with the Web Share API).
static func can_share(bridge: NetJsBridge) -> bool:
	return bridge != null and bridge.available() and _same(bridge.eval(JS_CAN_SHARE), true)


static func share(bridge: NetJsBridge, title: String, text: String) -> bool:
	if not can_share(bridge):
		return false
	return _same(bridge.eval(JS_SHARE % [JSON.stringify(title), JSON.stringify(text)]), JS_OK)


## The browser's text prompt (blocks until answered): the typed text, or null when
## cancelled or off the web.
static func prompt(bridge: NetJsBridge, message: String, default_text: String) -> Variant:
	if bridge == null or not bridge.available():
		return null
	var v: Variant = bridge.eval(JS_PROMPT % [JSON.stringify(message), JSON.stringify(default_text)])
	return v if v is String else null


## `v` is exactly `expected` (a page answer may be any type; never compare across types).
static func _same(v: Variant, expected: Variant) -> bool:
	return typeof(v) == typeof(expected) and v == expected


## Lays `c` at `at` with size `sz`.
static func place(c: Control, at: Vector2, sz: Vector2) -> void:
	c.position = at
	c.size = sz


## A text line's height (its minimum size) or 0 when hidden.
static func line_h(c: Control) -> float:
	return c.get_combined_minimum_size().y if c.visible else 0.0
