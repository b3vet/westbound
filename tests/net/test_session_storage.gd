extends WBTest
## Session storage per platform: the native encrypted user:// file (round trip, not
## plaintext, per-install key, atomic replace, clear) and the web localStorage path through
## a mock JavaScript bridge (round trip, escaping, Safari private mode and blocked
## storage). Spec: multiplayer handoff → Accounts (device secret storage); plan MP-D2.
## WP N1.2.

const DIR := "user://test_net_store"
const SECRET := "Zm9vYmFyYmF6cXV4cXV1eGNvcmdlZ3JhdWx0Z2FycGx5"

var _sessions: Array[NetSession] = []


func before_each() -> void:
	_wipe()


func after_each() -> void:
	for s in _sessions:
		if is_instance_valid(s):
			s.queue_free()
	_sessions.clear()
	await tree.process_frame
	_wipe()


func _wipe() -> void:
	for sub: String in ["", "/other"]:
		var d := DIR + sub
		if not DirAccess.dir_exists_absolute(d):
			continue
		for f in DirAccess.get_files_at(d):
			DirAccess.remove_absolute(d + "/" + f)
	if DirAccess.dir_exists_absolute(DIR + "/other"):
		DirAccess.remove_absolute(DIR + "/other")
	if DirAccess.dir_exists_absolute(DIR):
		DirAccess.remove_absolute(DIR)


func _file_store(salt_dir: String = DIR) -> NetFileStore:
	return NetFileStore.new("session", DIR, salt_dir + "/install.salt")


## Numbers as floats: JSON brings them back that way (the session reads them with int()).
func _doc() -> Dictionary:
	return {"v": 1.0, "account_id": "9223372036854775807", "device_secret": SECRET,
			"refresh_token": "rt-ü-\"quoted\"", "profile": {"display_name": "Şahin 34", "name_tag": 42.0}}


# ---------------------------------------------------------------- Native

func test_native_round_trip() -> void:
	var st := _file_store()
	eq(st.load_data(), {}, "nothing yet")
	check(st.save_data(_doc()))
	check(st.is_persistent())
	eq(st.kind(), "file")
	var again := _file_store().load_data()   # a new launch
	eq(again, _doc())
	check(again["account_id"] is String, "the id stays a String")
	check(FileAccess.file_exists(DIR + "/install.salt"), "per-install salt")
	check(not FileAccess.file_exists(st.path + NetFileStore.TMP_SUFFIX), "temporary file renamed away")


func test_native_file_is_not_plaintext() -> void:
	var st := _file_store()
	st.save_data(_doc())
	var raw := FileAccess.get_file_as_bytes(st.path)
	gt(raw.size(), 0)
	check(not raw.get_string_from_ascii().contains(SECRET), "the secret is not in the file")
	check(not raw.get_string_from_ascii().contains("device_secret"), "nor the keys")


func test_native_overwrite_and_clear() -> void:
	var st := _file_store()
	st.save_data(_doc())
	var d := _doc()
	d["refresh_token"] = "rotated"
	st.save_data(d)
	eq(_file_store().load_data()["refresh_token"], "rotated")
	check(st.clear())
	eq(_file_store().load_data(), {})
	check(st.clear(), "clearing twice is fine")


func test_native_other_install_key_cannot_read() -> void:
	_file_store().save_data(_doc())
	DirAccess.make_dir_recursive_absolute(DIR + "/other")
	var other := _file_store(DIR + "/other")   # another install's salt
	other.salt_path = DIR + "/other/install.salt"
	FileAccess.open(other.salt_path, FileAccess.WRITE).store_string("00ff")
	expect_errors(1)   # FileAccessEncrypted reports the MD5 mismatch
	eq(other.load_data(), {}, "a copied file does not open")


func test_session_resumes_from_the_native_file() -> void:
	var fake := NetFakeAccounts.new()
	var t := NetTuning.load_default()
	var s := _session(fake, _file_store(), t)
	await s.start()
	eq(s.status, NetSession.Status.ONLINE)
	check(s.storage_ok, "persistent store")
	s.queue_free()
	fake.requests.clear()
	var s2 := _session(fake, _file_store(), t)
	await s2.start()
	eq(s2.status, NetSession.Status.ONLINE)
	eq(fake.paths(), PackedStringArray([NetApi.PATH_REFRESH, NetApi.PATH_ME]), "resumed from the file")
	await s2.delete_account()
	eq(_file_store().load_data(), {}, "deletion clears the file")
	check(not FileAccess.file_exists(DIR + "/session.dat"))


func _session(fake: NetFakeAccounts, st: NetSessionStore, t: NetTuning) -> NetSession:
	var s := NetSession.new()
	s.auto_start = false
	s.configure(fake, st, t, NetVirtualTime.new(1), "https://store.test/api/v1", 1)
	tree.root.add_child(s)
	_sessions.append(s)
	return s


# ---------------------------------------------------------------- Web (mock bridge)

func test_web_round_trip_through_local_storage() -> void:
	var js := MockJs.new()
	var st := NetWebStore.new(js)
	eq(st.load_data(), {})
	check(st.save_data(_doc()))
	check(st.is_persistent())
	eq(st.kind(), "web")
	eq(js.storage.keys(), [NetWebStore.KEY_PREFIX], "one localStorage key")
	var parsed: Variant = JSON.parse_string(String(js.storage[NetWebStore.KEY_PREFIX]))
	eq(parsed, _doc(), "stored as JSON")
	eq(NetWebStore.new(js).load_data(), _doc(), "a new launch reads it")
	eq(js.installs, 2, "the helper installs once per store")
	check(st.clear())
	eq(js.storage.size(), 0)
	eq(NetWebStore.new(js).load_data(), {})


func test_web_store_names_per_server() -> void:
	var js := MockJs.new()
	NetWebStore.new(js, "session_abc").save_data({"a": "1"})
	check(js.storage.has(NetWebStore.KEY_PREFIX + ".session_abc"))
	eq(NetWebStore.new(js).load_data(), {}, "the default server's document is separate")


func test_web_private_mode_keeps_the_session_for_this_launch() -> void:
	var js := MockJs.new()
	js.set_throws = "QuotaExceededError"   # Safari private mode
	var st := NetWebStore.new(js)
	check(not st.save_data(_doc()), "the write fails")
	eq(st.last_error, "QuotaExceededError")
	check(not st.is_persistent())
	eq(st.load_data(), _doc(), "kept in memory for this launch")
	# The session works, and says the account is not saved.
	var fake := NetFakeAccounts.new()
	var s := _session(fake, NetWebStore.new(js), NetTuning.load_default())
	await s.start()
	eq(s.status, NetSession.Status.ONLINE)
	check(not s.storage_ok, "not saved on this device")
	var r := await s.rename("Road Runner")
	check(r.ok)


func test_web_blocked_storage_reads_as_empty() -> void:
	var js := MockJs.new()
	js.storage[NetWebStore.KEY_PREFIX] = JSON.stringify(_doc())
	js.all_throw = "SecurityError"
	var st := NetWebStore.new(js)
	eq(st.load_data(), {})
	check(not st.is_persistent())
	check(not st.clear())


func test_web_garbage_value_starts_fresh() -> void:
	var js := MockJs.new()
	js.storage[NetWebStore.KEY_PREFIX] = "{not json"
	eq(NetWebStore.new(js).load_data(), {})


func test_web_store_off_the_web_is_memory_only() -> void:
	var st := NetWebStore.new(NetJsBridge.new())   # headless: not the web
	check(not st.save_data(_doc()))
	check(not st.is_persistent())
	eq(st.load_data(), _doc())


func test_web_query_param_snippet_is_valid() -> void:
	var js := MockJs.new()
	js.search = "?server=http%3A%2F%2F127.0.0.1%3A8080&x=1"
	eq(js.query_param("server"), "http://127.0.0.1:8080")
	eq(js.query_param("missing"), "")


func test_platform_store_is_the_file_off_the_web() -> void:
	var st := NetSession.platform_store(NetSession.STORE_DEFAULT)
	eq(st.kind(), "file")
	eq((st as NetFileStore).path, NetFileStore.DIR + "/session.dat")


## A page stand-in: it answers the NetWebStore helper's calls from a Dictionary, the way
## the real helper answers from localStorage (tagged Strings), and URLSearchParams.get.
## The call arguments are parsed as JSON, so the store's snippets must be valid literals.
class MockJs:
	extends NetJsBridge
	var storage := {}
	var installs := 0
	var set_throws := ""
	var all_throw := ""
	var search := ""
	var _call := RegEx.create_from_string("^window\\.__wbNetStore\\.(get|set|remove)\\((.*)\\)$")
	var _param := RegEx.create_from_string("\\.get\\((\"(?:[^\"\\\\]|\\\\.)*\")\\)")

	func available() -> bool:
		return true

	func eval(code: String) -> Variant:
		if code == NetWebStore.HELPER_JS:
			installs += 1
			return "v"
		if code.contains("URLSearchParams"):
			var pm := _param.search(code)
			var key: Variant = JSON.parse_string(pm.get_string(1)) if pm != null else null
			for part in search.trim_prefix("?").split("&"):
				var kv := part.split("=")
				if kv.size() == 2 and kv[0] == key:
					return kv[1].uri_decode()
			return ""
		var m := _call.search(code)
		if m == null:
			return null
		var args: Variant = JSON.parse_string("[" + m.get_string(2) + "]")
		if not (args is Array):
			return null
		var a := args as Array
		if not all_throw.is_empty():
			return "!" + all_throw
		match m.get_string(1):
			"get":
				return "v" + String(storage[a[0]]) if storage.has(a[0]) else ""
			"set":
				if not set_throws.is_empty():
					return "!" + set_throws
				storage[a[0]] = a[1]
				return "v"
			"remove":
				storage.erase(a[0])
				return "v"
		return null
