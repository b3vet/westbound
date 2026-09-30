class_name TitleProfileChip
extends ScreenButton
## The title's profile chip (WP8.5): `name#tag` and the online status, top-right. Spec:
## UI → Screens (Title); multiplayer handoff → Accounts (names `name#1234`), Client
## changes (online status). docs/SCREENS.md → Title.
##
## Reads NetSession.current (the `Net` autoload when online features are on; none in
## native dev runs): the profile's full name (or PLAYER before the first sign-in) and the
## status word ProfilePanel uses (ONLINE, CONNECTING, OFFLINE, ...; ONLINE OFF without a
## session), with a status diamond: accent online, gold connecting, hot for a suspended
## or refused account, muted otherwise. A tap opens the account (the title's settings).
## A ScreenButton (BaseButton: emulated mouse events, never a raw touch index), at least
## touch_target_px tall; the name is shortened with "..." past title_chip_max_width_px.

const TEXT_PLAYER := "PLAYER"
const TEXT_NO_SESSION := "ONLINE OFF"
## Name and status line sizes (canvas px at 100% text size).
const NAME_PX := 20
const STATUS_PX := 14
## The status diamond's radius, a share of the status line's cap height.
const DOT_EM := 0.6   # lint: allow-number glyph proportion
const ELLIPSIS := "..."

var session: NetSession
var full_name: String = ""
var status_text: String = ""
var status: int = -1

var _cmesh := HudMesh.new()


func _init() -> void:
	super._init()
	name = "ProfileChip"
	kind = ScreenButton.Kind.NORMAL


## Reads the session (the bound one, else NetSession.current) and redraws when it changed.
func refresh() -> void:
	var s := _session()
	var n := TEXT_PLAYER
	var st := -1
	var word := TEXT_NO_SESSION
	if s != null:
		st = s.status
		word = String(ProfilePanel.STATUS_LABEL.get(s.status, TEXT_NO_SESSION))
		if s.profile != null and not s.profile.full_name.is_empty():
			n = s.profile.full_name
	if n != full_name or st != status or word != status_text:
		full_name = n
		status = st
		status_text = word
		text = n
		queue_redraw()


func _session() -> NetSession:
	if session != null and is_instance_valid(session):
		return session
	var c := NetSession.current
	return c if c != null and is_instance_valid(c) else null


func name_px() -> int:
	return maxi(1, roundi(float(NAME_PX) * (style.ts if style != null else 1.0)))


func status_px() -> int:
	return maxi(1, roundi(float(STATUS_PX) * (style.ts if style != null else 1.0)))


func _pad() -> float:
	return style.tuning.spacing_grid_px * 2.0


func _dot_r() -> float:
	return HudDraw.cap_height(status_px()) * DOT_EM


## The chip's width for its content, capped (the name is shortened past the cap), and
## at most `room` px when given (the title leaves it the space right of the logo).
func fit_width(room: float = INF) -> float:
	if style == null:
		return 0.0
	var t := style.tuning
	var nw := HudDraw.text_width(style.label, full_name, name_px())
	var sw := _dot_r() * 2.0 + t.spacing_grid_px + HudDraw.text_width(style.label, status_text, status_px())
	var w := maxf(nw, sw) + _pad() * 2.0 + ScreenButton.PRESS_SHIFT
	return ceilf(clampf(w, t.touch_target_px, minf(t.title_chip_max_width_px * style.ts, floorf(room))))


## The name as drawn (shortened with "..." when it does not fit).
func shown_name() -> String:
	if style == null:
		return full_name
	var max_w := size.x - _pad() * 2.0 - ScreenButton.PRESS_SHIFT
	var fs := name_px()
	if HudDraw.text_width(style.label, full_name, fs) <= max_w:
		return full_name
	var n := full_name.length()
	while n > 0:
		n -= 1
		var s := full_name.left(n) + ELLIPSIS
		if HudDraw.text_width(style.label, s, fs) <= max_w:
			return s
	return ""


func status_color() -> Color:
	match status:
		NetSession.Status.ONLINE:
			return style.accent
		NetSession.Status.CONNECTING:
			return style.gold
		NetSession.Status.BANNED, NetSession.Status.FAILED:
			return style.hot
	return style.muted


func _draw() -> void:
	redraws += 1
	if style == null:
		return
	var s := style
	var mode := get_draw_mode()
	var down := mode == DRAW_PRESSED or mode == DRAW_HOVER_PRESSED
	var hover := mode == DRAW_HOVER
	var off := Vector2(PRESS_SHIFT, PRESS_SHIFT) if down else Vector2.ZERO
	var r := Rect2(off, size - Vector2(PRESS_SHIFT, PRESS_SHIFT))
	var nfs := name_px()
	var sfs := status_px()
	var ncap := HudDraw.cap_height(nfs)
	var scap := HudDraw.cap_height(sfs)
	var gap := s.tuning.spacing_grid_px
	var pad := _pad()
	var block := ncap + gap + scap
	var top := r.position.y + (r.size.y - block) * 0.5
	var dot := _dot_r()
	var sc := status_color()
	_cmesh.begin()
	_cmesh.panel(r, s.bevel_control, Color(s.ink, 1.0) if down else s.panel_fill,
			s.accent if down or hover else s.edge_idle, s.edge_w)
	_cmesh.ngon(Vector2(r.position.x + pad + dot, top + ncap + gap + scap * 0.5), dot, 4, sc,
			Color.TRANSPARENT, 0.0, -PI * 0.25)
	_cmesh.flush(self)
	HudDraw.text(self, s.label, Vector2(r.position.x + pad, top + ncap), shown_name(), nfs,
			s.accent if down else s.text)
	HudDraw.text(self, s.label, Vector2(r.position.x + pad + dot * 2.0 + gap, top + block), status_text, sfs, sc)
