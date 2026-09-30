class_name SocialRow
extends Control
## One row of a social list (a friend, a request, a blocked player, a crew member): a
## faceted panel with the presence dot, `name` + `#tag` + the crew tag, a status line, and
## up to two touch buttons on the right. Spec: multiplayer handoff → Friends and presence
## (online status, a Join button when a friend is in a room with space), Crews (members
## with roles); UI, HUD and design system → Design system. WP N9.2; docs/SCREENS.md →
## Social.
##
## The name is shortened with "..." when the buttons leave it too little room, so no text
## runs under a button at either text size. Buttons are ScreenButtons (touch ids never
## index anything) as tall as the row, which is touch_target_px tall.

signal button_pressed(row: SocialRow, index: int)

enum Dot { NONE, OFFLINE, ONLINE, IN_ROOM }

const MAX_BUTTONS := 2
const TITLE_PX := 20
const LABEL_PX := 16
## The presence dot's diameter, px at 100% text size.
const DOT_PX := 10.0   # lint: allow-number look
const DOT_OFFLINE_A := 0.6   # lint: allow-number look

var style: HudStyle
var tuning: HudTuning
## The row's subject (null for an empty-list note row).
var player: NetSocialPlayer
## What the row is (&"friend", &"incoming", &"outgoing", &"blocked", &"member").
var kind: StringName = &""
## The action id of each button (the panel's choice), parallel to `buttons`.
var actions: Array[StringName] = []
var dot: Dot = Dot.NONE:
	set(value):
		if value != dot:
			dot = value
			if dot_view != null:
				dot_view.queue_redraw()
var selected: bool = false:
	set(value):
		selected = value
		if bg != null:
			bg.edge = ScreenPanel.Edge.ACCENT if value else ScreenPanel.Edge.IDLE
			bg.queue_redraw()

var bg: ScreenPanel
## Draws the presence dot (over the panel).
var dot_view: Control
var title: ScreenText
var tag: ScreenText
var badge: ScreenText
var sub: ScreenText
var buttons: Array[ScreenButton] = []

var _full_title: String = ""


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	bg = ScreenPanel.new()
	bg.tab = false
	bg.small_bevel = true
	add_child(bg)
	dot_view = Control.new()
	dot_view.name = "Dot"
	dot_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot_view.draw.connect(_draw_dot)
	add_child(dot_view)
	title = _text(ScreenText.Face.BODY, TITLE_PX, ScreenText.Ink.TEXT)
	tag = _text(ScreenText.Face.BODY, TITLE_PX, ScreenText.Ink.MUTED)
	tag.tabular = true
	badge = _text(ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.ACCENT)
	sub = _text(ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.MUTED)
	for i in MAX_BUTTONS:
		var b := ScreenButton.make("", ScreenButton.Kind.NORMAL, TITLE_PX)
		b.name = "Button%d" % i
		b.align = HORIZONTAL_ALIGNMENT_CENTER
		b.visible = false
		b.pressed.connect(func() -> void: button_pressed.emit(self, i))
		add_child(b)
		buttons.append(b)


## The button of action `id` (null when the row has none).
func button(id: StringName) -> ScreenButton:
	var i := actions.find(id)
	return buttons[i] if i >= 0 and i < MAX_BUTTONS and buttons[i].visible else null


func _text(face: ScreenText.Face, px: int, ink: ScreenText.Ink) -> ScreenText:
	var t := ScreenText.make("", face, px, ink)
	add_child(t)
	return t


func setup(s: HudStyle, t: HudTuning) -> void:
	style = s
	tuning = t
	bg.setup(s)
	for c: ScreenText in [title, tag, badge, sub]:
		c.setup(s)
	for b in buttons:
		b.setup(s)
		b.size_px = t.font_screen_body_px
	dot_view.queue_redraw()


## The row's texts: the name (shortened to fit), its `#1234`, the crew tag ("" none) and
## the status line in `sub_ink`.
func set_texts(name_text: String, tag_text: String, crew_tag: String, status_text: String,
		sub_ink: ScreenText.Ink = ScreenText.Ink.MUTED) -> void:
	_full_title = name_text
	title.text = name_text
	tag.text = tag_text
	badge.text = "[%s]" % crew_tag if not crew_tag.is_empty() else ""
	sub.text = status_text
	sub.set_ink(sub_ink)


## Up to two buttons, right to left in the order given (labels "" hide the rest), with
## their action ids.
func set_buttons(labels: Array[String], ids: Array[StringName] = [],
		kinds: Array[ScreenButton.Kind] = []) -> void:
	actions = ids.duplicate()
	for i in MAX_BUTTONS:
		var b := buttons[i]
		b.visible = i < labels.size() and not labels[i].is_empty()
		b.text = labels[i] if i < labels.size() else ""
		b.kind = kinds[i] if i < kinds.size() else ScreenButton.Kind.NORMAL
		# A primary's chevron sits at the right end: its label starts at the left.
		b.align = HORIZONTAL_ALIGNMENT_LEFT if b.kind == ScreenButton.Kind.PRIMARY else HORIZONTAL_ALIGNMENT_CENTER
		b.disabled = false
		b.note = ""
		b.queue_redraw()


## Lays the row out in `r` (parent-local px).
func layout(r: Rect2) -> void:
	position = r.position
	size = r.size
	if style == null:
		return
	var g := tuning.spacing_grid_px
	var pad := g * 2.0
	var right := r.size.x
	for b in buttons:
		if not b.visible:
			continue
		var w := SocialUi.button_width(b, tuning)
		right -= w
		SocialUi.place(b, Vector2(right, 0.0), Vector2(w, r.size.y))
		right -= g
	var bw := maxf(right, 0.0)
	SocialUi.place(bg, Vector2.ZERO, Vector2(bw, r.size.y))
	var x := pad
	var dot_w := 0.0
	if dot != Dot.NONE:
		dot_w = DOT_PX * style.ts + g
	var th := title.get_combined_minimum_size().y
	var sh := sub.get_combined_minimum_size().y
	var top := (r.size.y - th - sh) * 0.5
	var ts := tag.get_combined_minimum_size()
	var bs := badge.get_combined_minimum_size() if not badge.text.is_empty() else Vector2.ZERO
	var avail := bw - pad * 2.0 - dot_w - ts.x - (bs.x + g if bs.x > 0.0 else 0.0)
	SocialUi.fit_text(title, _full_title, maxf(avail, 0.0))
	var tw := title.get_combined_minimum_size().x
	var d := DOT_PX * style.ts
	dot_view.visible = dot != Dot.NONE
	SocialUi.place(dot_view, Vector2(x, top + (th - d) * 0.5), Vector2(d, d))
	x += dot_w
	SocialUi.place(title, Vector2(x, top), Vector2(tw, th))
	SocialUi.place(tag, Vector2(x + tw, top), ts)
	SocialUi.place(badge, Vector2(x + tw + ts.x + g, top + (th - bs.y) * 0.5), bs)
	SocialUi.fit_text(sub, sub.text, maxf(bw - pad * 2.0 - dot_w, 0.0))
	SocialUi.place(sub, Vector2(x, top + th), Vector2(sub.get_combined_minimum_size().x, sh))
	dot_view.queue_redraw()


func _draw_dot() -> void:
	if style == null or dot == Dot.NONE:
		return
	var c := Color(style.muted, style.muted.a * DOT_OFFLINE_A)
	if dot == Dot.ONLINE:
		c = style.accent
	elif dot == Dot.IN_ROOM:
		c = style.gold
	var r := dot_view.size.x * 0.5
	dot_view.draw_circle(Vector2(r, r), r, c)
