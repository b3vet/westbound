extends SceneTree
## Manual live check of NetSession + NetApi against a running server (not part of the
## test tiers: no `test_` prefix). Spec: multiplayer handoff → Accounts and
## authentication; docs/SERVER.md → Accounts API. WP N1.2; docs/NET_CLIENT.md → Live
## session check.
##
##   tools/godot.sh --headless --path . --script res://tests/net/live_session_check.gd -- \
##       http://127.0.0.1:8080 [--name="Road Runner"] [--keep]
##
## Uses a throwaway encrypted store (user://live_session_check/), never the game's. Steps:
## create (first launch) → resume (a second launch: refresh + /me) → rename → refresh
## reuse (the stored token used behind the session's back: device-login fallback) →
## logout → sign in → a NetClient Hello on the session's ws_url() with its token →
## delete (unless --keep). Prints one line per step, never a token or
## secret. Exit 0 when every step passes. Refuses the production server.

const DIR := "user://live_session_check"
const PROD_HOST := "westbound.sipsakrandevu.com"
const MAP_HASH_BYTES := 32
const CLIENT_BUILD := 1
const WS_TIMEOUT_MS := 5000

var _url := ""
var _name := "Road Runner"
var _keep := false
var _fails := 0
var _t: NetTuning


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--name="):
			_name = a.substr("--name=".length()).trim_prefix("\"").trim_suffix("\"")
		elif a == "--keep":
			_keep = true
		else:
			_url = a
	if _url.is_empty():
		printerr("usage: live_session_check.gd -- http://127.0.0.1:8080 [--name=NAME] [--keep]")
		quit(2)
		return
	if _url.contains(PROD_HOST):
		printerr("live_session_check: refusing the production server (use a local one)")
		quit(2)
		return
	_t = NetTuning.load_default()
	_run()


func _run() -> void:
	await process_frame   # the root enters the tree after _initialize
	_wipe()
	var base := NetSession.normalize_server(_url, "")
	print("server %s" % base)
	# 1. First launch: a device account.
	var s := _launch(base)
	await s.start()
	_step("create", s.status == NetSession.Status.ONLINE and s.profile != null,
			"account %s %s" % [s.account_id(), _who(s)])
	var id := s.account_id()
	var doc := _store().load_data()
	_step("stored", doc.get(NetSession.K_ACCOUNT) == id and doc.has(NetSession.K_SECRET)
			and doc.has(NetSession.K_REFRESH), "id, secret and refresh token in %s" % DIR)
	s.queue_free()
	# 2. Relaunch: resume by refresh.
	s = _launch(base)
	await s.start()
	_step("resume", s.status == NetSession.Status.ONLINE and s.account_id() == id,
			"refresh + /me, same account %s" % _who(s))
	var rotated := String(_store().load_data().get(NetSession.K_REFRESH, "")) != String(doc.get(NetSession.K_REFRESH, ""))
	_step("rotation", rotated, "a new refresh token was stored")
	# 3. Rename (a fresh account has no cooldown), then the mapped cooldown error.
	var r := await s.rename(_name)
	_step("rename", r.ok and s.profile.display_name == _name, _who(s) if r.ok else r.error)
	r = await s.rename(_name + "x")
	_step("rename again", r.error == "rename_cooldown",
			"%s: %s" % [r.error, NetSession.error_text(r, s.now_unix())])
	r = await s.rename("a__b")
	_step("invalid name", r.error == "invalid_name", "%s: %s" % [r.error, NetSession.error_text(r, 0.0)])
	s.queue_free()
	# 4. The stored refresh token is used elsewhere: the next launch falls back to the secret.
	var stale := String(_store().load_data().get(NetSession.K_REFRESH, ""))
	var api := NetApi.new(NetHttpNode.new(get_root()), _t, base)
	var used := await api.refresh(stale)
	s = _launch(base)
	await s.start()
	_step("reuse fallback", used.ok and s.status == NetSession.Status.ONLINE and s.account_id() == id,
			"token_reused -> device login, same account")
	# 5. Logout, then sign in with the device secret.
	await s.logout()
	var out_ok := s.status == NetSession.Status.SIGNED_OUT
	await s.retry()
	_step("logout + sign in", out_ok and s.status == NetSession.Status.ONLINE and s.account_id() == id, "")
	# 6. The realtime gateway accepts the session's token (dev servers accept a zero map hash).
	var token := await s.fresh_access_token()
	var client := NetClient.new(NetWsTransport.new(_t), _t)
	var zero_map := PackedByteArray()
	zero_map.resize(MAP_HASH_BYTES)
	client.start(s.ws_url(), CLIENT_BUILD, zero_map, token)
	var deadline := Time.get_ticks_msec() + WS_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline and client.get_state() != NetClient.State.READY \
			and client.get_state() != NetClient.State.FAILED:
		await process_frame
		client.poll()
	_step("ws hello", client.get_state() == NetClient.State.READY and client.account_id == id,
			"%s Welcome account %s" % [s.ws_url(), client.account_id] if client.get_state() == NetClient.State.READY
			else "%s: %s" % [client.failure_reason, client.failure_message])
	client.close()
	# 7. Delete.
	if not _keep:
		r = await s.delete_account()
		_step("delete", r.ok and _store().load_data().is_empty() and s.status == NetSession.Status.SIGNED_OUT,
				"204, local storage cleared")
		var gone := await NetApi.new(NetHttpNode.new(get_root()), _t, base).device_login(id, String(doc.get(NetSession.K_SECRET, "")))
		_step("deleted on server", gone.error == NetApiResult.INVALID_CREDENTIALS, "device login -> %s" % gone.error)
	s.queue_free()
	_wipe()
	print("LIVE_SESSION %s (%d failed)" % ["ok" if _fails == 0 else "FAILED", _fails])
	quit(0 if _fails == 0 else 1)


func _launch(base: String) -> NetSession:
	var s := NetSession.new()
	s.auto_start = false
	s.configure(NetHttpNode.new(s), _store(), _t, null, base)
	get_root().add_child(s)
	return s


func _store() -> NetFileStore:
	return NetFileStore.new("session", DIR, DIR + "/install.salt")


func _who(s: NetSession) -> String:
	return s.profile.full_name if s.profile != null else "(no profile)"


func _step(what: String, ok: bool, detail: String) -> void:
	if not ok:
		_fails += 1
	print("%-18s %s  %s" % [what, "ok  " if ok else "FAIL", detail])


func _wipe() -> void:
	if not DirAccess.dir_exists_absolute(DIR):
		return
	for f in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(DIR + "/" + f)
	DirAccess.remove_absolute(DIR)
