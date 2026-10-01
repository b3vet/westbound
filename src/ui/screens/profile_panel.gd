class_name ProfilePanel
extends Control
## The online account panel (pause menu → SETTINGS → ACCOUNT). Spec: multiplayer handoff
## → Client changes ("Profile and account: link Apple / Google, rename, ..., delete
## account"), Accounts and authentication (names `name#1234`, account deletion reachable
## from the profile screen); plan MP-D2 (device accounts only: Apple / Google show as
## coming soon). WP N1.2; docs/NET_CLIENT.md → Profile panel.
##
## Messages are kept under about 50 characters: screen text does not wrap.
## Left: the player card (name#tag, online status and what it means), then RENAME (a
## text field, SAVE, and the server's answer inline) or, when not signed in, TRY AGAIN
## (and NEW ACCOUNT when the stored account was refused). Right: SIGN IN WITH APPLE /
## GOOGLE, the cloud save line, then DELETE ACCOUNT with a confirm step (DELETE
## FOREVER / CANCEL). Everything talks to a NetSession (NetSession.current unless
## bound) and follows its signals; nothing here blocks the game.
##
## N11 (docs/NET_CLIENT.md → Account screen): a provider button signs in (links the
## identity to this account, or signs in when there is none here); a linked one shows
## SIGNED IN WITH … with the masked address and opens the unlink confirm. A provider the
## server has not set up shows NOT SET UP; one this build cannot open (no native plugin
## yet) NOT IN THIS BUILD. When the identity has its own account the column becomes the
## chooser: both accounts (name, level, runs), KEEP THIS DEVICE'S PROGRESS / USE THE CLOUD
## PROGRESS / CANCEL. Under the buttons, the cloud save's state (NetCloudSave).
##
## N9.2: a tab row on top (ACCOUNT / FRIENDS / CREW, shown when a session exists) swaps
## this view for the FriendsPanel or the CrewPanel in the same area, with the page
## controls at the row's right end; REPORT on either opens the shared ReportDialog over
## the area. The social screens live here rather than as a pause-menu button, so the pause
## menu's column stays as it is (N7.2 adds LEADERBOARDS there).
##
## Touch: the buttons are ScreenButtons (BaseButton: emulated mouse events, so raw touch
## ids never index anything) at least touch_target_px tall; the text field too. While
## the field has focus the run's PlayerInput stops reading keys (typing "P" must not
## unpause the game); it reads them again when the field loses focus or the panel hides.

const TEXT_PLAYER := "PLAYER"
const TEXT_RENAME := "RENAME"
const TEXT_ACCOUNT := "ACCOUNT"
const TEXT_SAVE := "SAVE"
const TEXT_APPLE := "SIGN IN WITH APPLE"
const TEXT_GOOGLE := "SIGN IN WITH GOOGLE"
## N11: the provider buttons' other states (notes under the label).
const TEXT_SIGN_IN_CAPTION := "SIGN IN"
const TEXT_APPLE_LINKED := "SIGNED IN WITH APPLE"
const TEXT_GOOGLE_LINKED := "SIGNED IN WITH GOOGLE"
const TEXT_NOT_SET_UP := "NOT SET UP"
const TEXT_NOT_HERE := "NOT IN THIS BUILD"
const TEXT_CHECKING := "CHECKING"
const TEXT_PRIVATE := "PRIVATE EMAIL"
const TEXT_TAP_UNLINK := "TAP TO UNLINK"
const TEXT_OPENING := "Opening %s..."
const TEXT_SIGNED_IN := "Signed in. Your progress is saved to the cloud."
const TEXT_CANCELLED := "Sign-in cancelled."
const TEXT_CONFLICT_TITLE := "THAT %s ACCOUNT HAS ITS OWN PROGRESS"
const TEXT_SIDE_DEVICE := "THIS DEVICE · LEVEL %d · %d RUNS"
const TEXT_SIDE_CLOUD := "CLOUD · LEVEL %d · %d RUNS"
const TEXT_SIDE_EMPTY := "CLOUD · NO SAVE YET"
const TEXT_CONFLICT_NOTE := "Either way, you switch to that account."
const TEXT_KEEP := "KEEP THIS DEVICE'S PROGRESS"
const TEXT_USE_CLOUD := "USE THE CLOUD PROGRESS"
const TEXT_SWITCHING := "Switching..."
const TEXT_SWITCHED := "Switched to %s."
const TEXT_UNCHANGED := "Nothing changed."
const TEXT_UNLINK_Q := "Unlink %s? You stay signed in here."
const TEXT_UNLINK_LAST := "Then only this device can open the account."
const TEXT_UNLINK := "UNLINK"
const TEXT_UNLINKED := "%s unlinked."
const TEXT_CLOUD_LINE := "CLOUD SAVE · %s"
const TEXT_CLOUD_OFF := "OFF UNTIL YOU SIGN IN"
const TEXT_CLOUD_ON := "ON"
const TEXT_CLOUD_SYNCING := "SYNCING"
const TEXT_CLOUD_SYNCED := "SYNCED"
const TEXT_CLOUD_SYNCED_AGO := "SYNCED %d MIN AGO"
const TEXT_CLOUD_WAITING := "UPDATES AFTER THIS RUN"
const TEXT_CLOUD_OFFLINE := "OFFLINE, WILL RETRY"
const TEXT_CLOUD_ERROR := "PAUSED"
const PROVIDER_NAMES := {"apple": "Apple", "google": "Google"}
## The longest masked address shown (longer ones are cut with "...").
const HINT_MAX_CHARS := 22
const S_PER_MIN := 60.0
const TEXT_DELETE := "DELETE ACCOUNT"
const TEXT_DELETE_FOREVER := "DELETE FOREVER"
const TEXT_CANCEL := "CANCEL"
const TEXT_RETRY := "TRY AGAIN"
const TEXT_SIGN_IN := "SIGN IN"
const TEXT_NEW_ACCOUNT := "NEW ACCOUNT"
const TEXT_PLACEHOLDER := "NEW NAME"
const TEXT_NO_ACCOUNT := "NO ACCOUNT YET"
const TEXT_CONFIRM_1 := "Delete your account, name and online data for good?"
const TEXT_CONFIRM_2 := "This cannot be undone. Single-player progress stays."
const TEXT_SAVING := "Saving..."
const TEXT_SAVED := "Name saved."
const TEXT_DELETING := "Deleting..."
const TEXT_DELETED := "Account deleted from the server and this device."
const TEXT_RENAME_HINT := "3–16 characters. One rename every 30 days."
const TEXT_TAB_ACCOUNT := "ACCOUNT"
const TEXT_TAB_FRIENDS := "FRIENDS"
const TEXT_TAB_CREW := "CREW"
const TEXT_TAB_NEW := "%d NEW"

enum View { ACCOUNT, FRIENDS, CREW }

## Status chip and note per NetSession.Status.
const STATUS_LABEL := {
	NetSession.Status.IDLE: "OFFLINE",
	NetSession.Status.CONNECTING: "CONNECTING",
	NetSession.Status.ONLINE: "ONLINE",
	NetSession.Status.OFFLINE: "OFFLINE",
	NetSession.Status.SIGNED_OUT: "SIGNED OUT",
	NetSession.Status.BANNED: "SUSPENDED",
	NetSession.Status.FAILED: "ACCOUNT ERROR",
	NetSession.Status.DISABLED: "ONLINE OFF",
}
const NOTE_ONLINE := "Device account, saved on this device."
## N11: signed in with a provider.
const NOTE_PROVIDER := "Signed in with %s. Plays on any device."
const NOTE_NOT_SAVED := "Not saved on this device (private browsing?)"
const NOTE_CONNECTING := "Signing in..."
const NOTE_OFFLINE := "Can't reach the server. Retrying by itself."
const NOTE_SIGNED_OUT := "Signed out on this device."
const NOTE_DISABLED := "Online features are off in this build."
const NOTE_NO_SESSION := "Online play is not available in this build."

## Name line size (display face) and body lines, canvas px at 100% text size.
const NAME_PX := 32
## The name's size steps down by this to fit the column (_fit_name).
const NAME_STEP_PX := 2
const LABEL_PX := 16
const BODY_PX := 16
## The rename row: SAVE's share of the column.
const SAVE_SHARE := 0.3   # lint: allow-number layout proportion
## Selection highlight opacity in the text field.
const SELECTION_A := 0.35   # lint: allow-number look

var style: HudStyle
var tuning: HudTuning
var session: NetSession
## The run's input hub: its key reading pauses while a text field has focus.
var hub: PlayerInput:
	set(value):
		hub = value
		if friends != null:
			friends.hub = value
			crew.hub = value
## The social client (null: NetSocialClient.of the session when a tab opens).
var social: NetSocialClient
var view: View = View.ACCOUNT
var confirming: bool = false
var busy: bool = false
## N11: the conflict chooser is showing / the provider whose unlink is being confirmed.
var choosing: bool = false
var unlinking: String = ""

var card: ScreenPanel
var caption: ScreenText
var name_text: ScreenText
var tag_text: ScreenText
var status_text: ScreenText
var status_note: ScreenText
var rename_caption: ScreenText
var name_edit: SocialField
var save_button: ScreenButton
var rename_note: ScreenText
var retry_button: ScreenButton
var new_account_button: ScreenButton
var link_caption: ScreenText
var apple_button: ScreenButton
var google_button: ScreenButton
var account_caption: ScreenText
var delete_button: ScreenButton
var confirm_text_1: ScreenText
var confirm_text_2: ScreenText
var confirm_button: ScreenButton
var cancel_button: ScreenButton
var delete_note: ScreenText
## N11 widgets.
var identity_note: ScreenText
var cloud_text: ScreenText
var conflict_title: ScreenText
var conflict_device: ScreenText
var conflict_device_name: ScreenText
var conflict_cloud: ScreenText
var conflict_cloud_name: ScreenText
var conflict_note: ScreenText
var keep_button: ScreenButton
var use_cloud_button: ScreenButton
var conflict_cancel_button: ScreenButton
var unlink_text_1: ScreenText
var unlink_text_2: ScreenText
var unlink_button: ScreenButton
var unlink_cancel_button: ScreenButton
var tabs: Array[ScreenButton] = []
var friends: FriendsPanel
var crew: CrewPanel
var report: ReportDialog

var _keys_muted: bool = false
var _area: Rect2 = Rect2()


func _init() -> void:
	name = "Profile"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	card = ScreenPanel.new()
	add_child(card)
	caption = _text(TEXT_PLAYER, ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.MUTED)
	name_text = _text("", ScreenText.Face.DISPLAY, NAME_PX, ScreenText.Ink.TEXT)
	tag_text = _text("", ScreenText.Face.DISPLAY, NAME_PX, ScreenText.Ink.MUTED)
	tag_text.tabular = true
	status_text = _text("", ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.ACCENT)
	status_note = _text("", ScreenText.Face.BODY, BODY_PX, ScreenText.Ink.MUTED)
	rename_caption = _text(TEXT_RENAME, ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.MUTED)
	name_edit = SocialField.new()
	name_edit.name = "NameEdit"
	name_edit.placeholder_text = TEXT_PLACEHOLDER
	name_edit.text_submitted.connect(func(_t: String) -> void: save())
	name_edit.focus_entered.connect(_mute_keys.bind(true))
	name_edit.focus_exited.connect(_mute_keys.bind(false))
	add_child(name_edit)
	save_button = _button(TEXT_SAVE, ScreenButton.Kind.PRIMARY, save)
	rename_note = _text("", ScreenText.Face.BODY, BODY_PX, ScreenText.Ink.MUTED)
	retry_button = _button(TEXT_RETRY, ScreenButton.Kind.NORMAL, retry)
	new_account_button = _button(TEXT_NEW_ACCOUNT, ScreenButton.Kind.NORMAL, new_account)
	link_caption = _text(TEXT_SIGN_IN_CAPTION, ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.MUTED)
	apple_button = _button(TEXT_APPLE, ScreenButton.Kind.NORMAL, tap_provider.bind(NetIdentityProvider.APPLE))
	google_button = _button(TEXT_GOOGLE, ScreenButton.Kind.NORMAL, tap_provider.bind(NetIdentityProvider.GOOGLE))
	apple_button.name = "AppleButton"
	google_button.name = "GoogleButton"
	identity_note = _text("", ScreenText.Face.BODY, BODY_PX, ScreenText.Ink.MUTED)
	cloud_text = _text("", ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.MUTED)
	conflict_title = _text("", ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.GOLD)
	conflict_device = _text("", ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.MUTED)
	conflict_device_name = _text("", ScreenText.Face.BODY, BODY_PX, ScreenText.Ink.TEXT)
	conflict_cloud = _text("", ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.MUTED)
	conflict_cloud_name = _text("", ScreenText.Face.BODY, BODY_PX, ScreenText.Ink.TEXT)
	conflict_note = _text(TEXT_CONFLICT_NOTE, ScreenText.Face.BODY, BODY_PX, ScreenText.Ink.MUTED)
	keep_button = _button(TEXT_KEEP, ScreenButton.Kind.PRIMARY, resolve_conflict.bind(true))
	keep_button.name = "KeepButton"
	use_cloud_button = _button(TEXT_USE_CLOUD, ScreenButton.Kind.NORMAL, resolve_conflict.bind(false))
	use_cloud_button.name = "UseCloudButton"
	conflict_cancel_button = _button(TEXT_CANCEL, ScreenButton.Kind.NORMAL, cancel_conflict)
	conflict_cancel_button.name = "ConflictCancel"
	unlink_text_1 = _text("", ScreenText.Face.BODY, BODY_PX, ScreenText.Ink.TEXT)
	unlink_text_2 = _text(TEXT_UNLINK_LAST, ScreenText.Face.BODY, BODY_PX, ScreenText.Ink.MUTED)
	unlink_button = _button(TEXT_UNLINK, ScreenButton.Kind.DANGER, confirm_unlink)
	unlink_button.name = "UnlinkButton"
	unlink_cancel_button = _button(TEXT_CANCEL, ScreenButton.Kind.NORMAL, cancel_unlink)
	unlink_cancel_button.name = "UnlinkCancel"
	account_caption = _text(TEXT_ACCOUNT, ScreenText.Face.LABEL, LABEL_PX, ScreenText.Ink.MUTED)
	delete_button = _button(TEXT_DELETE, ScreenButton.Kind.DANGER, ask_delete)
	confirm_text_1 = _text(TEXT_CONFIRM_1, ScreenText.Face.BODY, BODY_PX, ScreenText.Ink.HOT)
	confirm_text_2 = _text(TEXT_CONFIRM_2, ScreenText.Face.BODY, BODY_PX, ScreenText.Ink.MUTED)
	confirm_button = _button(TEXT_DELETE_FOREVER, ScreenButton.Kind.DANGER, confirm_delete)
	cancel_button = _button(TEXT_CANCEL, ScreenButton.Kind.NORMAL, cancel_delete)
	delete_note = _text("", ScreenText.Face.BODY, BODY_PX, ScreenText.Ink.MUTED)
	var labels: Array[String] = [TEXT_TAB_ACCOUNT, TEXT_TAB_FRIENDS, TEXT_TAB_CREW]
	for i in labels.size():
		var b := _button(labels[i], ScreenButton.Kind.OPTION, show_view.bind(i))
		b.name = "Tab" + labels[i].capitalize()
		tabs.append(b)
	friends = FriendsPanel.new()
	friends.visible = false
	friends.report_requested.connect(_open_report)
	add_child(friends)
	crew = CrewPanel.new()
	crew.visible = false
	crew.report_requested.connect(_open_report)
	add_child(crew)
	report = ReportDialog.new()
	report.closed.connect(_on_report_closed)
	report.visibility_changed.connect(_on_report_visibility)
	add_child(report)


func _text(value: String, face: ScreenText.Face, px: int, ink: ScreenText.Ink) -> ScreenText:
	var t := ScreenText.make(value, face, px, ink)
	add_child(t)
	return t


func _button(label: String, kind: ScreenButton.Kind, action: Callable) -> ScreenButton:
	var b := ScreenButton.make(label, kind, 20)
	b.name = label.capitalize().replace(" ", "")
	if action.is_valid():
		b.pressed.connect(action)
	add_child(b)
	return b


## The design system (the pause screen's style and HUD tuning).
func setup(s: HudStyle, t: HudTuning) -> void:
	style = s
	tuning = t
	for c in get_children():
		if c is ScreenText:
			(c as ScreenText).setup(s)
		elif c is ScreenButton:
			(c as ScreenButton).setup(s)
			(c as ScreenButton).size_px = t.font_screen_body_px
		elif c is ScreenPanel:
			(c as ScreenPanel).setup(s)
	friends.setup(s, t)
	crew.setup(s, t)
	report.setup(s, t)
	_style_edit()
	refresh()


## Follows `s` (null: NetSession.current when the panel shows).
func bind(s: NetSession) -> void:
	_connect(false)
	session = s
	_connect(true)
	refresh()


## A session is there to show (the pause menu hides its ACCOUNT button otherwise).
func has_session() -> bool:
	return _session() != null


func _session() -> NetSession:
	if session != null and is_instance_valid(session):
		return session
	var c := NetSession.current
	return c if c != null and is_instance_valid(c) else null


func _connect(on: bool) -> void:
	if session == null or not is_instance_valid(session):
		return
	var sigs: Array[Signal] = [session.status_changed, session.profile_changed, session.signed_in,
			session.signed_out, session.banned, session.providers_loaded, session.account_switched]
	if session.cloud != null:
		sigs.append(session.cloud.status_changed)
		sigs.append(session.cloud.synced)
	for sig in sigs:
		if on and not sig.is_connected(_on_session_signal):
			sig.connect(_on_session_signal)
		elif not on and sig.is_connected(_on_session_signal):
			sig.disconnect(_on_session_signal)


func _on_session_signal(_a: Variant = null) -> void:
	refresh()


## Shows the panel fresh (the ACCOUNT tab, no confirm step, no old messages).
func open() -> void:
	if session == null:
		bind(_session())
	view = View.ACCOUNT
	report.visible = false
	friends.visible = false
	crew.visible = false
	confirming = false
	unlinking = ""
	var s := _session()
	choosing = s != null and not s.pending_conflict.is_empty()
	rename_note.text = ""
	delete_note.text = ""
	identity_note.text = ""
	name_edit.text = ""
	if s != null:
		s.load_providers()
	refresh()


func _exit_tree() -> void:
	_connect(false)
	_mute_keys(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree():
		if name_edit != null and name_edit.has_focus():
			name_edit.release_focus()
		_mute_keys(false)


# ---------------------------------------------------------------- Actions

func save() -> void:
	var s := _session()
	if s == null or busy:
		return
	name_edit.release_focus()
	busy = true
	_note(rename_note, TEXT_SAVING, ScreenText.Ink.MUTED)
	var r: NetApiResult = await s.rename(name_edit.text)
	busy = false
	if r.ok:
		name_edit.text = ""
		_note(rename_note, TEXT_SAVED, ScreenText.Ink.ACCENT)
	else:
		_note(rename_note, NetSession.error_text(r, s.now_unix()), ScreenText.Ink.HOT)
	refresh()


func ask_delete() -> void:
	confirming = true
	delete_note.text = ""
	refresh()


func cancel_delete() -> void:
	confirming = false
	refresh()


func confirm_delete() -> void:
	var s := _session()
	if s == null or busy:
		return
	busy = true
	_note(delete_note, TEXT_DELETING, ScreenText.Ink.MUTED)
	var r: NetApiResult = await s.delete_account()
	busy = false
	confirming = false
	if r.ok:
		rename_note.text = ""
		_note(delete_note, TEXT_DELETED, ScreenText.Ink.ACCENT)
	else:
		_note(delete_note, NetSession.error_text(r, s.now_unix()), ScreenText.Ink.HOT)
	refresh()


# ---------------------------------------------------------------- Sign in with Apple / Google (N11)

## A provider button: sign in (not linked) or the unlink confirm (linked).
func tap_provider(provider: String) -> void:
	var s := _session()
	if s == null or busy:
		return
	if s.profile != null and s.profile.is_linked(provider) and s.status == NetSession.Status.ONLINE:
		unlinking = provider
		confirming = false
		identity_note.text = ""
		refresh()
		return
	busy = true
	_note(identity_note, TEXT_OPENING % String(PROVIDER_NAMES.get(provider, provider)), ScreenText.Ink.MUTED)
	refresh()
	var r: NetApiResult = await s.sign_in_with(provider)
	busy = false
	if r.ok:
		_note(identity_note, TEXT_SIGNED_IN, ScreenText.Ink.ACCENT)
	elif r.error == NetSession.ERR_IDENTITY_IN_USE:
		choosing = true
		identity_note.text = ""
	elif r.error == NetIdentityResult.CANCELLED:
		_note(identity_note, TEXT_CANCELLED, ScreenText.Ink.MUTED)
	else:
		_note(identity_note, NetSession.error_text(r, s.now_unix()), ScreenText.Ink.HOT)
	refresh()


## The chooser: switch to the identity's account, keeping this device's progress (merged
## in) or using the cloud's.
func resolve_conflict(keep_device: bool) -> void:
	var s := _session()
	if s == null or busy:
		return
	busy = true
	_note(identity_note, TEXT_SWITCHING, ScreenText.Ink.MUTED)
	refresh()
	var r: NetApiResult = await s.resolve_conflict(keep_device)
	busy = false
	if r.ok:
		choosing = false
		var who := s.profile.full_name if s.profile != null else ""
		_note(identity_note, TEXT_SWITCHED % who, ScreenText.Ink.ACCENT)
	else:
		_note(identity_note, NetSession.error_text(r, s.now_unix()), ScreenText.Ink.HOT)
		if r.error == "id_token_expired" or r.error == "invalid_nonce" or r.error == NetSession.ERR_NO_CONFLICT:
			s.cancel_conflict()
			choosing = false
	refresh()


func cancel_conflict() -> void:
	var s := _session()
	if s != null:
		s.cancel_conflict()
	choosing = false
	_note(identity_note, TEXT_UNCHANGED, ScreenText.Ink.MUTED)
	refresh()


func confirm_unlink() -> void:
	var s := _session()
	if s == null or busy or unlinking.is_empty():
		return
	var provider := unlinking
	busy = true
	refresh()
	var r: NetApiResult = await s.unlink(provider)
	busy = false
	unlinking = ""
	if r.ok:
		_note(identity_note, TEXT_UNLINKED % String(PROVIDER_NAMES.get(provider, provider)), ScreenText.Ink.ACCENT)
	else:
		_note(identity_note, NetSession.error_text(r, s.now_unix()), ScreenText.Ink.HOT)
	refresh()


func cancel_unlink() -> void:
	unlinking = ""
	refresh()


## A provider button's label, note and whether it can be tapped.
func _provider_button(b: ScreenButton, provider: String, s: NetSession) -> void:
	var linked := s != null and s.profile != null and s.profile.is_linked(provider) \
			and s.status != NetSession.Status.SIGNED_OUT
	var apple := provider == NetIdentityProvider.APPLE
	b.text = (TEXT_APPLE_LINKED if apple else TEXT_GOOGLE_LINKED) if linked else (TEXT_APPLE if apple else TEXT_GOOGLE)
	b.selected = linked
	if s == null:
		b.note = TEXT_NOT_SET_UP
		b.disabled = true
		return
	if linked:
		var hint := s.profile.email_hint(provider)
		b.note = TEXT_PRIVATE if s.profile.private_email(provider) else (short_hint(hint) if not hint.is_empty() else TEXT_TAP_UNLINK)
		b.disabled = busy or s.status != NetSession.Status.ONLINE
		return
	if s.provider_config.is_empty():
		b.note = TEXT_CHECKING
		b.disabled = true
	elif not s.provider_enabled(provider):
		b.note = TEXT_NOT_SET_UP
		b.disabled = true
	elif not s.provider_available(provider):
		b.note = TEXT_NOT_HERE
		b.disabled = true
	else:
		b.note = ""
		var can := s.status == NetSession.Status.ONLINE or s.status == NetSession.Status.SIGNED_OUT \
				or s.status == NetSession.Status.FAILED
		b.disabled = busy or not can or s.identity_busy()


## A masked address short enough for a button note.
static func short_hint(hint: String) -> String:
	if hint.length() <= HINT_MAX_CHARS:
		return hint.to_upper()
	return (hint.left(HINT_MAX_CHARS - 3) + "...").to_upper()


## The chooser's two lines: this device's account and progress, the identity's.
func _conflict_lines(s: NetSession) -> void:
	var c := s.pending_conflict
	var p := str(c.get("provider", ""))
	conflict_title.text = TEXT_CONFLICT_TITLE % String(PROVIDER_NAMES.get(p, p)).to_upper()
	var cur: Variant = c.get("current", {})
	var other: Variant = c.get("other", {})
	var has_target := s.cloud != null and s.cloud.target != null
	var local := SaveMerge.summary(s.cloud.target.snapshot() if has_target else Save.snapshot())
	var prog := Garage.tuning()
	conflict_device.text = TEXT_SIDE_DEVICE % [Progression.level_for_xp(int(local[SaveMerge.STAT_XP]), prog),
			int(local[SaveMerge.STAT_RUNS])]
	conflict_device_name.text = _name_of(cur)
	var cs: Variant = (other as Dictionary).get("cloud_save") if other is Dictionary else null
	if cs is Dictionary:
		var xp := _whole((cs as Dictionary).get("xp"))
		conflict_cloud.text = TEXT_SIDE_CLOUD % [Progression.level_for_xp(xp, prog), _whole((cs as Dictionary).get("runs"))]
	else:
		conflict_cloud.text = TEXT_SIDE_EMPTY
	conflict_cloud_name.text = _name_of(other)


## A JSON number as a whole number (0 for null or anything else).
static func _whole(v: Variant) -> int:
	return int(v) if (v is int or v is float) and is_finite(float(v)) else 0


static func _name_of(side: Variant) -> String:
	if side is Dictionary:
		return NetApiResult.as_id((side as Dictionary).get("full_name", ""))
	return ""


## The cloud save line.
func _cloud_line(s: NetSession) -> String:
	var c: NetCloudSave = s.cloud if s != null else null
	if c == null or not c.enabled():
		return TEXT_CLOUD_LINE % TEXT_CLOUD_OFF
	match c.status:
		NetCloudSave.Status.SYNCING:
			return TEXT_CLOUD_LINE % TEXT_CLOUD_SYNCING
		NetCloudSave.Status.WAITING:
			return TEXT_CLOUD_LINE % TEXT_CLOUD_WAITING
		NetCloudSave.Status.OFFLINE:
			return TEXT_CLOUD_LINE % TEXT_CLOUD_OFFLINE
		NetCloudSave.Status.ERROR:
			return TEXT_CLOUD_LINE % TEXT_CLOUD_ERROR
		NetCloudSave.Status.SYNCED:
			var mins := floori((s.now_unix() - float(c.last_sync_unix)) / S_PER_MIN)
			return TEXT_CLOUD_LINE % (TEXT_CLOUD_SYNCED if mins < 1 else TEXT_CLOUD_SYNCED_AGO % mins)
	return TEXT_CLOUD_LINE % TEXT_CLOUD_ON


func retry() -> void:
	var s := _session()
	if s != null:
		s.retry()
	refresh()


func new_account() -> void:
	var s := _session()
	if s != null:
		s.create_new_account()
	refresh()


## Switches the tab (View): ACCOUNT, FRIENDS or CREW. The social tabs load from the
## server as they open.
func show_view(v: int) -> void:
	view = v as View
	report.visible = false
	var c := _social()
	friends.bind(c)
	crew.bind(c)
	friends.hub = hub
	crew.hub = hub
	friends.visible = view == View.FRIENDS
	crew.visible = view == View.CREW
	if view == View.FRIENDS:
		friends.open()
	elif view == View.CREW:
		crew.open()
	refresh()


## The session's social client (or the injected one).
func _social() -> NetSocialClient:
	if social != null:
		return social
	return NetSocialClient.of(_session())


func _open_report(p: NetSocialPlayer, context: Dictionary) -> void:
	report.open_for(_social(), p.account_id, p.full_name, context)


## The dialog covers the tab's area: the tab's panel hides under it.
func _on_report_visibility() -> void:
	friends.visible = view == View.FRIENDS and not report.visible
	crew.visible = view == View.CREW and not report.visible


func _on_report_closed(_sent: bool) -> void:
	refresh()


func _note(t: ScreenText, value: String, ink: ScreenText.Ink) -> void:
	t.text = value
	t.set_ink(ink)
	_layout()


# ---------------------------------------------------------------- View

## Re-reads the session into the widgets.
func refresh() -> void:
	var s := _session()
	var st: NetSession.Status = s.status if s != null else NetSession.Status.DISABLED
	var p: NetProfile = s.profile if s != null else null
	var shown := p != null and st != NetSession.Status.SIGNED_OUT
	name_text.text = p.display_name if shown else TEXT_NO_ACCOUNT
	name_text.set_ink(ScreenText.Ink.TEXT if shown else ScreenText.Ink.MUTED)
	tag_text.text = p.tag_text() if shown else ""
	status_text.text = String(STATUS_LABEL.get(st, ""))
	match st:
		NetSession.Status.ONLINE:
			status_text.set_ink(ScreenText.Ink.ACCENT)
		NetSession.Status.BANNED, NetSession.Status.FAILED:
			status_text.set_ink(ScreenText.Ink.HOT)
		_:
			status_text.set_ink(ScreenText.Ink.MUTED)
	status_note.text = _status_note(s, st)
	var online := st == NetSession.Status.ONLINE
	var can_retry := s != null and (st == NetSession.Status.OFFLINE or st == NetSession.Status.FAILED
			or st == NetSession.Status.BANNED or st == NetSession.Status.SIGNED_OUT)
	rename_caption.visible = online
	name_edit.visible = online
	name_edit.editable = online and not busy
	save_button.visible = online
	save_button.disabled = busy
	if online and rename_note.text.is_empty():
		_note_quiet(rename_note, _rename_hint(s, p), ScreenText.Ink.MUTED)
	rename_note.visible = online or not rename_note.text.is_empty()
	retry_button.visible = can_retry and not online
	retry_button.text = TEXT_SIGN_IN if st == NetSession.Status.SIGNED_OUT else TEXT_RETRY
	new_account_button.visible = st == NetSession.Status.FAILED
	var can_delete := s != null and (online or st == NetSession.Status.BANNED)
	delete_button.visible = can_delete and not confirming
	for c: CanvasItem in [confirm_text_1, confirm_text_2, confirm_button, cancel_button]:
		c.visible = can_delete and confirming
	confirm_button.disabled = busy
	account_caption.visible = can_delete or not delete_note.text.is_empty()
	delete_note.visible = not delete_note.text.is_empty()
	var nt: NetTuning = s.tuning if s != null else null
	name_edit.max_length = nt.display_name_max_chars if nt != null else 0
	name_edit.net_tuning = nt
	_provider_button(apple_button, NetIdentityProvider.APPLE, s)
	_provider_button(google_button, NetIdentityProvider.GOOGLE, s)
	if choosing and (s == null or s.pending_conflict.is_empty()):
		choosing = false
	if choosing:
		_conflict_lines(s)
	cloud_text.text = _cloud_line(s)
	var cloud_ink := ScreenText.Ink.MUTED
	if s != null and s.cloud != null and s.cloud.status == NetCloudSave.Status.SYNCED:
		cloud_ink = ScreenText.Ink.ACCENT
	elif s != null and s.cloud != null and s.cloud.status == NetCloudSave.Status.ERROR:
		cloud_ink = ScreenText.Ink.HOT
	cloud_text.set_ink(cloud_ink)
	if unlinking != "":
		var pname := String(PROVIDER_NAMES.get(unlinking, unlinking))
		unlink_text_1.text = TEXT_UNLINK_Q % pname
		var others := s != null and s.profile != null and ((unlinking == "apple" and s.profile.linked_google)
				or (unlinking == "google" and s.profile.linked_apple))
		unlink_text_2.text = "" if others else TEXT_UNLINK_LAST
	keep_button.disabled = busy
	use_cloud_button.disabled = busy
	conflict_cancel_button.disabled = busy
	unlink_button.disabled = busy
	var tabbed := s != null
	for i in tabs.size():
		tabs[i].visible = tabbed
		tabs[i].selected = i == int(view)
	var c := social if social != null else (NetSocialClient.of(s) if tabbed else null)
	var waiting := c.incoming.size() if c != null else 0
	tabs[View.FRIENDS].note = TEXT_TAB_NEW % waiting if waiting > 0 else ""
	if not tabbed:
		view = View.ACCOUNT
	var acct := view == View.ACCOUNT
	for ci: CanvasItem in [card, caption, name_text, tag_text, status_text, status_note]:
		ci.visible = acct
	# The right column: the chooser, the unlink confirm, or the buttons and the account's
	# deletion.
	var normal := acct and not choosing and unlinking.is_empty()
	for ci: CanvasItem in [link_caption, apple_button, google_button, cloud_text]:
		ci.visible = normal
	identity_note.visible = acct and not identity_note.text.is_empty()
	for ci: CanvasItem in [conflict_title, conflict_device, conflict_device_name, conflict_cloud,
			conflict_cloud_name, conflict_note, keep_button,
			use_cloud_button, conflict_cancel_button]:
		ci.visible = acct and choosing
	for ci: CanvasItem in [unlink_text_1, unlink_button, unlink_cancel_button]:
		ci.visible = acct and not choosing and not unlinking.is_empty()
	unlink_text_2.visible = acct and not choosing and not unlinking.is_empty() and not unlink_text_2.text.is_empty()
	if choosing:
		for ci: CanvasItem in [rename_caption, name_edit, save_button, rename_note, retry_button,
				new_account_button]:
			ci.visible = false
	if not normal:
		delete_button.visible = false
		account_caption.visible = false
		delete_note.visible = false
		for ci: CanvasItem in [confirm_text_1, confirm_text_2, confirm_button, cancel_button]:
			ci.visible = false
	if not acct:
		for ci in _account_items():
			ci.visible = false
	_layout()


## The ACCOUNT tab's own widgets.
func _account_items() -> Array[CanvasItem]:
	return [card, caption, name_text, tag_text, status_text, status_note, rename_caption, name_edit,
			save_button, rename_note, retry_button, new_account_button, link_caption, apple_button,
			google_button, account_caption, delete_button, confirm_text_1, confirm_text_2, confirm_button,
			cancel_button, delete_note, identity_note, cloud_text, conflict_title, conflict_device,
			conflict_device_name, conflict_cloud, conflict_cloud_name, conflict_note, keep_button, use_cloud_button, conflict_cancel_button,
			unlink_text_1, unlink_text_2, unlink_button, unlink_cancel_button]


func _note_quiet(t: ScreenText, value: String, ink: ScreenText.Ink) -> void:
	t.text = value
	t.set_ink(ink)


static func _status_note(s: NetSession, st: NetSession.Status) -> String:
	if s == null:
		return NOTE_NO_SESSION
	match st:
		NetSession.Status.ONLINE:
			if not s.storage_ok:
				return NOTE_NOT_SAVED
			if s.profile != null and s.profile.has_provider():
				return NOTE_PROVIDER % ("Apple" if s.profile.linked_apple else "Google")
			return NOTE_ONLINE
		NetSession.Status.CONNECTING, NetSession.Status.IDLE:
			return NOTE_CONNECTING
		NetSession.Status.OFFLINE:
			return NOTE_OFFLINE
		NetSession.Status.SIGNED_OUT:
			return NOTE_SIGNED_OUT
		NetSession.Status.BANNED:
			return NetSession.banned_text(s.banned_until)
		NetSession.Status.FAILED:
			return NetSession.error_text(s.last_error, s.now_unix())
		NetSession.Status.DISABLED:
			return NOTE_DISABLED
	return ""


static func _rename_hint(s: NetSession, p: NetProfile) -> String:
	if s != null and p != null and not p.can_rename(s.now_unix()):
		return NetSession.cooldown_text(p.next_rename_at, s.now_unix())
	return TEXT_RENAME_HINT


func _style_edit() -> void:
	if style == null or tuning == null:
		return
	var border := UiTheme.border_px(tuning)
	var pad := tuning.spacing_grid_px * 2.0
	var normal := UiTheme.box(tuning.control_bevel_px, border, style.panel_fill, style.edge_idle)
	var focus := UiTheme.box(tuning.control_bevel_px, border, Color(style.ink, 1.0), style.accent)
	var off := UiTheme.box(tuning.control_bevel_px, border, style.panel_fill, Color(style.muted, SELECTION_A))
	for b: StyleBoxFlat in [normal, focus, off]:
		b.content_margin_left = pad
		b.content_margin_right = pad
	name_edit.add_theme_stylebox_override(&"normal", normal)
	name_edit.add_theme_stylebox_override(&"focus", focus)
	name_edit.add_theme_stylebox_override(&"read_only", off)
	name_edit.add_theme_font_override(&"font", style.body)
	name_edit.add_theme_font_size_override(&"font_size", maxi(1, roundi(float(tuning.font_screen_button_px) * style.ts)))
	name_edit.add_theme_color_override(&"font_color", style.text)
	name_edit.add_theme_color_override(&"font_placeholder_color", style.muted)
	name_edit.add_theme_color_override(&"font_uneditable_color", style.muted)
	name_edit.add_theme_color_override(&"caret_color", style.accent)
	name_edit.add_theme_color_override(&"selection_color", Color(style.accent, SELECTION_A))


## Lays the panel out in `area` (panel-local px), or again in the last area.
func layout(area: Rect2) -> void:
	_area = area
	_layout()


func _layout() -> void:
	if style == null or tuning == null or _area.size.x <= 0.0:
		return
	var g := tuning.spacing_grid_px
	var th := tuning.touch_target_px
	var gap := g * 2.0
	var cw := (_area.size.x - gap * 2.0) * 0.5
	var lx := _area.position.x
	var rx := lx + cw + gap * 2.0
	var top := _area.position.y
	if tabs[0].visible:
		var tx := lx
		for b in tabs:
			var w := SocialUi.button_width(b, tuning)
			_place(b, Vector2(tx, top), Vector2(w, th))
			tx += w + g
		var header := Rect2(tx + g, top, _area.end.x - tx - g, th)
		top += th + gap
		var body := Rect2(lx, top, _area.size.x, _area.end.y - top)
		friends.layout(body, header)
		crew.layout(body, header)
		report.layout(body)
		if view != View.ACCOUNT:
			return
	var y := top
	# Player card.
	var cs := caption.get_combined_minimum_size()
	_fit_name(cw - gap * 2.0 - g * 0.5)
	var ns := name_text.get_combined_minimum_size()
	var ss := status_text.get_combined_minimum_size()
	var sn := status_note.get_combined_minimum_size()
	var inner := lx + gap
	var cy := y + gap
	_place(caption, Vector2(inner, cy), cs)
	cy += cs.y
	_place(name_text, Vector2(inner, cy), ns)
	_place(tag_text, Vector2(inner + ns.x + g * 0.5, cy), tag_text.get_combined_minimum_size())
	cy += ns.y
	_place(status_text, Vector2(inner, cy), ss)
	cy += ss.y
	_place(status_note, Vector2(inner, cy), Vector2(cw - gap * 2.0, sn.y))
	cy += sn.y + gap
	card.position = Vector2(lx, y)
	card.size = Vector2(cw, cy - y)
	y = cy + gap
	# The chooser's CANCEL and notes take the left column (the right one holds both
	# accounts and the two choices); otherwise rename, or the sign-in actions.
	if choosing:
		_place(conflict_cancel_button, Vector2(lx, y), Vector2(cw, th))
		y += th + g
		y = _line(conflict_note, lx, y, cw)
		_line(identity_note, lx, y, cw)
	elif name_edit.visible:
		var rs := rename_caption.get_combined_minimum_size()
		_place(rename_caption, Vector2(lx, y), rs)
		y += rs.y
		var sw := maxf(cw * SAVE_SHARE, save_button.get_combined_minimum_size().x)
		name_edit.position = Vector2(lx, y)
		name_edit.size = Vector2(cw - sw - g, th)
		save_button.position = Vector2(lx + cw - sw, y)
		save_button.size = Vector2(sw, th)
		y += th + g
	elif retry_button.visible:
		var n := 2 if new_account_button.visible else 1
		var bw := (cw - g * float(n - 1)) / float(n)
		retry_button.position = Vector2(lx, y)
		retry_button.size = Vector2(bw, th)
		new_account_button.position = Vector2(lx + bw + g, y)
		new_account_button.size = Vector2(bw, th)
		y += th + g
	_place(rename_note, Vector2(lx, y), Vector2(cw, rename_note.get_combined_minimum_size().y))
	# Right column: the chooser, or the unlink confirm, or sign-in and the account's deletion.
	var ry := top
	if choosing:
		for t: ScreenText in [conflict_title, conflict_device, conflict_device_name, conflict_cloud,
				conflict_cloud_name]:
			ry = _line(t, rx, ry, cw)
		ry += g
		for b: ScreenButton in [keep_button, use_cloud_button]:
			_place(b, Vector2(rx, ry), Vector2(cw, th))
			ry += th + g
		return
	if not unlinking.is_empty():
		ry = _line(unlink_text_1, rx, ry, cw)
		if unlink_text_2.visible:
			ry = _line(unlink_text_2, rx, ry, cw)
		ry += g
		var bw3 := (cw - g) * 0.5
		_place(unlink_button, Vector2(rx, ry), Vector2(bw3, th))
		_place(unlink_cancel_button, Vector2(rx + bw3 + g, ry), Vector2(bw3, th))
		ry += th + g
		_line(identity_note, rx, ry, cw)
		return
	var ls := link_caption.get_combined_minimum_size()
	_place(link_caption, Vector2(rx, ry), ls)
	ry += ls.y
	for b: ScreenButton in [apple_button, google_button]:
		b.position = Vector2(rx, ry)
		b.size = Vector2(cw, th)
		ry += th + g
	ry = _line(cloud_text, rx, ry, cw)
	if identity_note.visible:
		ry = _line(identity_note, rx, ry, cw)
	ry += g
	var acs := account_caption.get_combined_minimum_size()
	_place(account_caption, Vector2(rx, ry), acs)
	ry += acs.y
	if confirming:
		for t: ScreenText in [confirm_text_1, confirm_text_2]:
			var s := t.get_combined_minimum_size()
			_place(t, Vector2(rx, ry), Vector2(cw, s.y))
			ry += s.y
		ry += g
		var bw2 := (cw - g) * 0.5
		confirm_button.position = Vector2(rx, ry)
		confirm_button.size = Vector2(bw2, th)
		cancel_button.position = Vector2(rx + bw2 + g, ry)
		cancel_button.size = Vector2(bw2, th)
		ry += th + g
	elif delete_button.visible:
		delete_button.position = Vector2(rx, ry)
		delete_button.size = Vector2(cw, th)
		ry += th + g
	_place(delete_note, Vector2(rx, ry), Vector2(cw, delete_note.get_combined_minimum_size().y))


## The name and its tag in one line of `width`: the widest names (16 W's at 125 % text)
## step the name size down until they fit (never below the body size).
func _fit_name(width: float) -> void:
	var px := NAME_PX
	while true:
		for st: ScreenText in [name_text, tag_text]:
			if st.size_px != px:
				st.size_px = px
				st.update_minimum_size()
				st.queue_redraw()
		var w := name_text.get_combined_minimum_size().x + tag_text.get_combined_minimum_size().x
		if w <= width or px <= BODY_PX:
			return
		px -= NAME_STEP_PX


## Places a text line at (x, y), `w` wide; returns the y under it.
static func _line(t: ScreenText, x: float, y: float, w: float) -> float:
	var h := t.get_combined_minimum_size().y
	_place(t, Vector2(x, y), Vector2(w, h))
	return y + h


static func _place(c: Control, at: Vector2, sz: Vector2) -> void:
	c.position = at
	c.size = sz


func _mute_keys(on: bool) -> void:
	if on == _keys_muted:
		return
	_keys_muted = on
	if hub != null and is_instance_valid(hub):
		hub.set_process_input(not on)
