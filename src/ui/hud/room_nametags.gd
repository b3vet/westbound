class_name RoomNametags
extends Control
## Nametags over the other players' cars, in one layer. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md
## → Players ("Every remote car shows a nametag in its crew color"), Rooms → Quick chat
## ("a horn and a few emotes shown on the nametag"), Client changes → Performance
## ("nametags are drawn in one layer"). docs/ROOMS_CLIENT.md → Room HUD. WP N5.2.
##
## One Control draws every tag (name#tag [CREW] in the crew color, outlined, and the
## player's latest quick chat under it for room_chat_show_s): the glyphs batch by font. A
## tag's text is built only when its member or member version changes; positions are
## projected from world space once per frame by set_tag(). Never takes touches.

var style: HudStyle
var net: NetTuning
## () -> float: now in seconds (the chat line's age).
var clock: Callable
## Redraws (tests).
var redraws: int = 0

var _pos := PackedVector2Array()
var _shown := PackedByteArray()
var _alpha := PackedFloat32Array()
var _color: Array[Color] = []
var _text: Array[String] = []
var _chat: Array[String] = []
var _member: Array[NetRoomMember] = []
var _name_of: Array[String] = []
var _any: bool = false


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE


func setup(s: HudStyle, net_tuning: NetTuning, slots: int) -> void:
	style = s
	net = net_tuning
	_pos.resize(slots)
	_shown.resize(slots)
	_shown.fill(0)
	_alpha.resize(slots)
	_color.resize(slots)
	_text.resize(slots)
	_chat.resize(slots)
	_member.resize(slots)
	_name_of.resize(slots)
	queue_redraw()


## Tag i over `world` (projected with the viewport's camera; hidden behind it).
func set_tag(i: int, world: Vector3, m: NetRoomMember, color: Color, alpha: float) -> void:
	if i < 0 or i >= _pos.size():
		return
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null or cam.is_position_behind(world):
		hide_tag(i)
		return
	_pos[i] = cam.unproject_position(world)
	if _member[i] != m or _name_of[i] != m.display_name:
		_member[i] = m
		_name_of[i] = m.display_name
		_text[i] = m.nametag()
	var chat := ""
	if not m.chat_text.is_empty() and clock.is_valid() and float(clock.call()) - m.chat_at_s < net.room_chat_show_s:
		chat = m.chat_text
	_chat[i] = chat
	_color[i] = color
	_alpha[i] = alpha
	_shown[i] = 1
	_any = true
	queue_redraw()


func hide_tag(i: int) -> void:
	if i >= 0 and i < _shown.size() and _shown[i] != 0:
		_shown[i] = 0
		queue_redraw()


func hide_all() -> void:
	if _any:
		_shown.fill(0)
		_any = false
		queue_redraw()


func is_shown(i: int) -> bool:
	return i >= 0 and i < _shown.size() and _shown[i] != 0


func text_of(i: int) -> String:
	return _text[i] if is_shown(i) else ""


func chat_of(i: int) -> String:
	return _chat[i] if is_shown(i) else ""


func position_of(i: int) -> Vector2:
	return _pos[i]


func _draw() -> void:
	redraws += 1
	if style == null or net == null:
		return
	var s := style
	var fs := maxi(1, roundi(float(net.room_nametag_font_px) * s.ts))
	var line := HudDraw.cap_height(fs) * 2.0
	for i in _shown.size():
		if _shown[i] == 0:
			continue
		var c := Color(_color[i], _alpha[i])
		var w := HudDraw.text_width(s.label, _text[i], fs)
		var p := _pos[i] - Vector2(w * 0.5, 0.0)
		HudDraw.text(self, s.label, p, _text[i], fs, c, s.outline_px, Color(s.outline, s.outline.a * _alpha[i]))
		if not _chat[i].is_empty():
			var cw := HudDraw.text_width(s.label, _chat[i], fs)
			HudDraw.text(self, s.label, _pos[i] + Vector2(-cw * 0.5, -line), _chat[i], fs,
				Color(s.gold, _alpha[i]), s.outline_px, Color(s.outline, s.outline.a * _alpha[i]))
