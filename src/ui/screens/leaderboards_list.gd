class_name LeaderboardsList
extends Control
## The leaderboard list: a fixed pool of LeaderboardsRow controls scrolled over the
## page's entries (100 entries never make 100 controls), drag and fling scrolling, pull
## to refresh, taps that select a row, and the player's own row pinned at the bottom when
## it is not in view. Spec: multiplayer handoff → Leaderboards (views; "around me"),
## Client changes → Leaderboards screen; UI → Design system; Controls (touch). WP N7.2;
## docs/SCREENS.md → Leaderboards.
##
## Touch: it reads the mouse events Godot emulates from touches (press, motion with the
## button held, release), so raw touch ids (large on iOS Safari) never index anything.
## A press that moves less than `boards_tap_slop_px` is a tap. Dragging down at the top
## pulls the list (half the finger's travel); letting go past `boards_pull_refresh_px`
## asks for a refresh. The wheel scrolls a row per notch. The rows sit in a clipping
## child above the pinned row.

signal row_tapped(index: int)
signal refresh_requested()
## The pull state changed: PULL_NONE, PULL_MORE (keep pulling), PULL_READY (let go).
signal pull_changed(state: int)

enum { PULL_NONE, PULL_MORE, PULL_READY }

## Pull resistance: the list moves this share of the finger's travel.
const PULL_GIVE := 0.5
## The pull springs back at this many list heights per second.
const PULL_RETURN := 4.0   # lint: allow-number animation speed
## Fling speeds below this (px/s) stop.
const FLING_STOP := 20.0   # lint: allow-number animation threshold
## Release speed: the drag's last moves are averaged with this weight.
const VELOCITY_BLEND := 0.5
## Rows beyond the visible ones (one partly shown at each end).
const SPARE_ROWS := 2

var style: HudStyle
var net: NetTuning
var page: NetBoardPage
var my_id: String = ""
var distance: bool = false
var miles: bool = false
## The selected entry index (-1: none).
var selected: int = -1
## Scroll offset in px (0 = the top row at the top).
var scroll: float = 0.0
## Overscroll at the top (px, pull to refresh).
var pull: float = 0.0
var velocity: float = 0.0
var rows: Array[LeaderboardsRow] = []
var pinned: LeaderboardsRow
## The rows' clipping area (the list above the pinned row).
var clip: Control

var _dragging: bool = false
var _moved: bool = false
var _press_y: float = 0.0
var _last_y: float = 0.0
var _travel: float = 0.0
var _pull_state: int = PULL_NONE
var _last_usec: int = 0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	clip = Control.new()
	clip.name = "Clip"
	clip.clip_contents = true
	clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(clip)
	pinned = LeaderboardsRow.new()
	pinned.name = "Pinned"
	pinned.visible = false
	add_child(pinned)
	set_process(false)


func setup(s: HudStyle, t: NetTuning) -> void:
	style = s
	net = t
	pinned.setup(s, t)
	for r in rows:
		r.setup(s, t)
	_layout()


func row_h() -> float:
	return net.boards_row_px * style.ts if net != null and style != null else 1.0


## Shows `p` (null: empty). `keep_scroll`: the same board refreshed; otherwise the list
## goes back to the top.
func set_page(p: NetBoardPage, my_account_id: String, keep_scroll: bool = false) -> void:
	page = p
	my_id = my_account_id
	selected = -1
	if not keep_scroll:
		scroll = 0.0
		velocity = 0.0
	scroll = clampf(scroll, 0.0, max_scroll())
	_layout()


func count() -> int:
	return page.entries.size() if page != null else 0


## The index of the player's own row (-1 when not listed).
func my_index() -> int:
	return page.my_index(my_id) if page != null else -1


## Scrolls so that entry `index` sits in the middle of the list.
func center_on(index: int) -> void:
	if index < 0:
		return
	scroll = clampf((float(index) + 0.5) * row_h() - list_height() * 0.5, 0.0, max_scroll())
	_layout()


## The height the rows scroll in (the pinned row takes the bottom when shown).
func list_height() -> float:
	return maxf(0.0, size.y - (row_h() if _pin_shown() else 0.0))


func max_scroll() -> float:
	return maxf(0.0, float(count()) * row_h() - list_height())


## The entry index under a point (local px), -1 outside the rows.
func index_at(p: Vector2) -> int:
	if p.y < 0.0 or p.y >= list_height():
		return -1
	var i := floori((p.y - pull + scroll) / row_h())
	return i if i >= 0 and i < count() else -1


## The pool row showing entry `index` (null when it is not in view).
func row_of(index: int) -> LeaderboardsRow:
	for r in rows:
		if r.visible and r.entry != null and index >= 0 and index < count() and r.entry == page.entries[index]:
			return r
	return null


func select(index: int) -> void:
	selected = index
	_layout()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout()


## The pinned own row shows when the player has an entry that is not in view.
func _pin_shown() -> bool:
	if page == null or page.me == null or page.me.rank <= 0:
		return false
	var mi := my_index()
	if mi < 0:
		return true
	var top := float(mi) * row_h() - scroll
	return top < 0.0 or top + row_h() > size.y


func _layout() -> void:
	if style == null or net == null:
		return
	var rh := row_h()
	var shown := _pin_shown()
	var lh := list_height()
	var need := ceili(lh / rh) + SPARE_ROWS
	while rows.size() < need:
		var r := LeaderboardsRow.new()
		r.name = "Row%d" % rows.size()
		r.setup(style, net)
		clip.add_child(r)
		rows.append(r)
	clip.position = Vector2.ZERO
	clip.size = Vector2(size.x, lh)
	var first := floori(scroll / rh)
	var frac := scroll - float(first) * rh
	for i in rows.size():
		var r := rows[i]
		var idx := first + i
		var y := float(i) * rh - frac + pull
		if idx >= count() or y >= lh or y + rh <= 0.0:
			r.visible = false
			continue
		r.visible = true
		r.position = Vector2(0.0, y)
		r.size = Vector2(size.x, rh)
		var e := page.entries[idx]
		r.bind(e, page.is_mine(e, my_id), idx == selected, distance, miles)
	pinned.visible = shown
	if shown:
		pinned.position = Vector2(0.0, size.y - rh)
		pinned.size = Vector2(size.x, rh)
		pinned.bind(page.me, true, false, distance, miles)


# ---------------------------------------------------------------- Input

func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null:
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_press(mb.position.y)
			elif _dragging:
				_release(mb.position)
			accept_event()
		elif mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_DOWN or mb.button_index == MOUSE_BUTTON_WHEEL_UP):
			var dir := 1.0 if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN else -1.0
			scroll = clampf(scroll + dir * row_h(), 0.0, max_scroll())
			_layout()
			accept_event()
		return
	var mm := event as InputEventMouseMotion
	if mm != null and _dragging and (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		_drag_to(mm.position.y)
		accept_event()


func _press(y: float) -> void:
	_dragging = true
	_moved = false
	_press_y = y
	_last_y = y
	_travel = 0.0
	velocity = 0.0
	_last_usec = Time.get_ticks_usec()
	set_process(false)


func _drag_to(y: float) -> void:
	var dy := y - _last_y
	_last_y = y
	_travel = maxf(_travel, absf(y - _press_y))
	if _travel >= net.boards_tap_slop_px:
		_moved = true
	if not _moved:
		return
	var now := Time.get_ticks_usec()
	var dt := maxf(float(now - _last_usec) / USEC_PER_S, MIN_DT)
	_last_usec = now
	velocity = lerpf(velocity, -dy / dt, VELOCITY_BLEND)
	if pull > 0.0 or (scroll <= 0.0 and dy > 0.0):
		pull = maxf(0.0, pull + dy * PULL_GIVE)
		scroll = 0.0
	else:
		scroll = clampf(scroll - dy, 0.0, max_scroll())
	_set_pull_state()
	_layout()


func _release(p: Vector2) -> void:
	_dragging = false
	if not _moved:
		var i := index_at(p)
		if i >= 0:
			row_tapped.emit(i)
		return
	if pull >= net.boards_pull_refresh_px:
		refresh_requested.emit()
	if pull > 0.0:
		velocity = 0.0
	set_process(pull > 0.0 or absf(velocity) > FLING_STOP)


func _process(delta: float) -> void:
	var busy := false
	if pull > 0.0 and not _dragging:
		pull = maxf(0.0, pull - maxf(size.y, 1.0) * PULL_RETURN * delta)
		busy = pull > 0.0
		_set_pull_state()
	elif absf(velocity) > FLING_STOP:
		scroll = clampf(scroll + velocity * delta, 0.0, max_scroll())
		velocity *= maxf(0.0, 1.0 - net.boards_fling_decay * delta)
		if scroll <= 0.0 or scroll >= max_scroll():
			velocity = 0.0
		busy = absf(velocity) > FLING_STOP
	_layout()
	if not busy:
		velocity = 0.0
		set_process(false)


func _set_pull_state() -> void:
	var st := PULL_NONE
	if pull > 0.0:
		st = PULL_READY if pull >= net.boards_pull_refresh_px else PULL_MORE
	if st != _pull_state:
		_pull_state = st
		pull_changed.emit(st)


func pull_state() -> int:
	return _pull_state


## Stops any pull or fling at once (tests, snaps, a new page).
func settle() -> void:
	pull = 0.0
	velocity = 0.0
	_dragging = false
	set_process(false)
	_set_pull_state()
	_layout()


const USEC_PER_S := 1000000.0
## Shortest time step for the release speed (two motion events in one frame).
const MIN_DT := 0.001   # lint: allow-number time epsilon
