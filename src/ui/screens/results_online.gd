class_name ResultsOnline
extends ScreenPanel
## The results screen's online line: where the run placed ("#12 THIS WEEK · #340 ALL
## TIME"), NEW PB, VERIFYING, and the states before or instead of that ("SUBMITTING...",
## "OFFLINE — WILL SUBMIT", "UPDATE REQUIRED"). Spec: multiplayer handoff → Leaderboards
## (single-player runs submitted when a run ends; "the score shows as verifying until
## checked"); docs/SERVER.md → POST /runs (placements, verification, reason). WP N7.2;
## docs/SCREENS.md → Results → Online.
##
## Fed a NetRunSubmission (show()); the results screen places it under the tiles and
## animates it in when the placements arrive. Never blocks the results.

const TEXT_CAPTION := "ONLINE"
const TEXT_SENDING := "SUBMITTING..."
const TEXT_OFFLINE := "OFFLINE — WILL SUBMIT"
const TEXT_RATE_LIMITED := "WILL SUBMIT SHORTLY"
const TEXT_SIGN_IN := "NOT SIGNED IN — WILL SUBMIT"
const TEXT_BANNED := "ACCOUNT SUSPENDED"
const TEXT_UPDATE := "UPDATE REQUIRED"
const NOTE_UPDATE := "Update Westbound to post scores online."
const TEXT_REJECTED := "NOT RANKED"
const NOTE_REJECTED := "This run didn't pass the server's checks."
const TEXT_FAILED := "COULDN'T SUBMIT"
const TEXT_EXPIRED := "TOO OLD TO SUBMIT"
const TEXT_SUBMITTED := "SUBMITTED"
const TEXT_NEW_PB := "NEW PB"
const TEXT_VERIFYING := "VERIFYING"
const TEXT_WEEK := "THIS WEEK"
const TEXT_ALL_TIME := "ALL TIME"
const TEXT_TODAY := "TODAY"
const TEXT_YESTERDAY := "YESTERDAY"
const TEXT_DISTANCE := "#%s DISTANCE"
const TEXT_RANK := "#%s %s"
const SEPARATOR := "  ·  "
const S_PER_DAY := 86400.0

## Type sizes, canvas px at 100% text size.
const CAPTION_PX := 13
const LINE_PX := 22
const NOTE_PX := 14
const CHIP_PX := 13

var caption: ScreenText
var line: ScreenText
var note: ScreenText
var pb_chip: ScreenPanel
var pb_text: ScreenText
var verifying_chip: ScreenPanel
var verifying_text: ScreenText
## What is shown (null: nothing: the panel hides).
var sub: NetRunSubmission


func _init() -> void:
	super._init()
	name = "Online"
	caption = ScreenText.make(TEXT_CAPTION, ScreenText.Face.LABEL, CAPTION_PX, ScreenText.Ink.MUTED)
	add_child(caption)
	line = ScreenText.make("", ScreenText.Face.BODY, LINE_PX, ScreenText.Ink.TEXT)
	add_child(line)
	note = ScreenText.make("", ScreenText.Face.LABEL, NOTE_PX, ScreenText.Ink.MUTED)
	add_child(note)
	pb_chip = ScreenPanel.new()
	pb_chip.gold_fill = true
	pb_chip.small_bevel = true
	pb_chip.tab = false
	add_child(pb_chip)
	pb_text = ScreenText.make(TEXT_NEW_PB, ScreenText.Face.LABEL, CHIP_PX, ScreenText.Ink.INK)
	pb_chip.add_child(pb_text)
	verifying_chip = ScreenPanel.new()
	verifying_chip.small_bevel = true
	verifying_chip.tab = false
	verifying_chip.edge = ScreenPanel.Edge.ACCENT
	add_child(verifying_chip)
	verifying_text = ScreenText.make(TEXT_VERIFYING, ScreenText.Face.LABEL, CHIP_PX, ScreenText.Ink.ACCENT)
	verifying_chip.add_child(verifying_text)


## Fills the panel from `s` (null hides it); `today` is the UTC date (Daily's label).
func show_submission(s: NetRunSubmission, today: String) -> void:
	sub = s
	visible = s != null
	if s == null:
		return
	var n := ""
	var ink := ScreenText.Ink.MUTED
	var line_text := ""
	match s.state:
		NetRunSubmission.State.QUEUED:
			line_text = _waiting_text(s.waiting)
			ink = ScreenText.Ink.HOT if s.waiting == NetRunSubmission.WAIT_BANNED else ScreenText.Ink.MUTED
		NetRunSubmission.State.SENDING:
			line_text = TEXT_SENDING
		NetRunSubmission.State.DONE:
			line_text = placement_text(s, today)
			ink = ScreenText.Ink.TEXT
			if line_text.is_empty():
				line_text = TEXT_SUBMITTED
			n = distance_text(s)
		NetRunSubmission.State.REJECTED:
			ink = ScreenText.Ink.HOT
			line_text = TEXT_UPDATE if s.update_required() else TEXT_REJECTED
			n = NOTE_UPDATE if s.update_required() else NOTE_REJECTED
		NetRunSubmission.State.FAILED:
			line_text = TEXT_FAILED
			ink = ScreenText.Ink.HOT
		NetRunSubmission.State.EXPIRED:
			line_text = TEXT_EXPIRED
	line.text = line_text
	line.set_ink(ink)
	note.text = n
	note.visible = not n.is_empty()
	var done := s.state == NetRunSubmission.State.DONE
	pb_chip.visible = done and s.new_pb()
	verifying_chip.visible = done and s.verifying
	layout_panel()


static func _waiting_text(why: String) -> String:
	match why:
		NetRunSubmission.WAIT_RATE_LIMITED:
			return TEXT_RATE_LIMITED
		NetRunSubmission.WAIT_SIGN_IN:
			return TEXT_SIGN_IN
		NetRunSubmission.WAIT_BANNED:
			return TEXT_BANNED
	return TEXT_OFFLINE


## "#12 THIS WEEK  ·  #340 ALL TIME" (Journey), "#3 TODAY" (Daily Drive).
static func placement_text(s: NetRunSubmission, today: String) -> String:
	var parts := PackedStringArray()
	for p in s.mode_placements():
		var rank := NetRunSubmission.rank_of(p)
		if rank <= 0:
			continue
		parts.append(TEXT_RANK % [HudFormat.thousands(rank), period_label(String(p.get("board", "")),
				String(p.get("period", "")), today)])
	return SEPARATOR.join(parts)


## "#812 DISTANCE" when the run fed the Distance board with a rank.
static func distance_text(s: NetRunSubmission) -> String:
	var rank := NetRunSubmission.rank_of(s.placement(NetBoards.DISTANCE, NetBoards.PERIOD_ALL))
	return TEXT_DISTANCE % HudFormat.thousands(rank) if rank > 0 else ""


static func period_label(board: String, period: String, today: String) -> String:
	if period == NetBoards.PERIOD_ALL:
		return TEXT_ALL_TIME
	if board == NetBoards.DAILY:
		if period == today:
			return TEXT_TODAY
		var t := NetRunPayload.date_start(today)
		if t >= 0 and period == NetRunPayload.utc_date(float(t) - S_PER_DAY):
			return TEXT_YESTERDAY
		return LeaderboardsScreen.date_label(period)
	return TEXT_WEEK


## Sizes the panel to its content and places its parts (the results screen then places
## the panel). Needs the style.
func layout_panel() -> void:
	if style == null:
		return
	var g := style.tuning.spacing_grid_px
	var pad := style.tuning.panel_padding_px * style.ts
	var cs := caption.get_combined_minimum_size()
	caption.position = Vector2(pad, pad)
	caption.size = cs
	var x := pad + cs.x + g * 2.0
	var chip_h := 0.0
	for pair: Array in [[pb_chip, pb_text], [verifying_chip, verifying_text]]:
		var chip := pair[0] as ScreenPanel
		var t := pair[1] as ScreenText
		if not chip.visible:
			continue
		var ts := t.get_combined_minimum_size()
		chip.size = Vector2(ts.x + g * 2.0, ts.y + g * 0.5)
		chip.position = Vector2(x, pad + (cs.y - chip.size.y) * 0.5)
		t.position = Vector2(g, g * 0.25)
		t.size = ts
		chip_h = maxf(chip_h, chip.size.y)
		x += chip.size.x + g
	var top := pad + maxf(cs.y, chip_h) + g * 0.5
	var ls := line.get_combined_minimum_size()
	line.position = Vector2(pad, top)
	line.size = ls
	var w := maxf(x - g + pad, pad * 2.0 + ls.x)
	var h := top + ls.y
	if note.visible:
		var ns := note.get_combined_minimum_size()
		note.position = Vector2(pad, h)
		note.size = ns
		w = maxf(w, pad * 2.0 + ns.x)
		h += ns.y
	size = Vector2(w, h + pad)
