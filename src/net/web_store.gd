class_name NetWebStore
extends NetSessionStore
## Web session storage: the JSON document in the page's localStorage. Spec: multiplayer
## handoff → Accounts ("Web: local storage"); plan MP-D2. WP N1.2; docs/NET_CLIENT.md →
## Storage.
##
## localStorage can throw (Safari private mode: setItem raises QuotaExceededError; a
## sandboxed iframe or blocked site data: even reading it throws). Every call goes through
## a small helper installed once in the page that catches everything and answers with a
## tagged String: "v<value>" (found), "" (absent), "!<ErrorName>" (failed). When a write
## fails the store keeps the document in memory for this launch and `is_persistent()`
## turns false, so the session can say "not saved on this device".

const KEY_PREFIX := "westbound.net.v1"
const HELPER := "__wbNetStore"
const HELPER_JS := """window.__wbNetStore = window.__wbNetStore || {
	get: function (k) { try { var v = window.localStorage.getItem(k); return v === null ? '' : 'v' + v; } catch (e) { return '!' + ((e && e.name) || 'Error'); } },
	set: function (k, v) { try { window.localStorage.setItem(k, v); return 'v'; } catch (e) { return '!' + ((e && e.name) || 'Error'); } },
	remove: function (k) { try { window.localStorage.removeItem(k); return 'v'; } catch (e) { return '!' + ((e && e.name) || 'Error'); } }
}; 'v';"""

var bridge: NetJsBridge
var key: String
## The last error name from the page ("" = none).
var last_error: String = ""

var _installed: bool = false
var _persistent: bool = true


func _init(js: NetJsBridge, doc_name: String = "") -> void:
	bridge = js
	key = KEY_PREFIX if doc_name.is_empty() else "%s.%s" % [KEY_PREFIX, doc_name]


func load_data() -> Dictionary:
	var v := _call("get", [key])
	if v.begins_with("!"):
		_persistent = false
		return super.load_data()
	if v.is_empty():
		return super.load_data()   # nothing stored (or this launch's memory copy)
	var j := JSON.new()
	if j.parse(v.substr(1)) != OK or not (j.data is Dictionary):
		push_warning("NetWebStore: the stored session is not a JSON object; starting fresh")
		return {}
	return j.data as Dictionary


func save_data(doc: Dictionary) -> bool:
	super.save_data(doc)   # memory copy: the launch goes on even when the page refuses
	var v := _call("set", [key, JSON.stringify(doc)])
	_persistent = not v.begins_with("!")
	return _persistent


func clear() -> bool:
	super.clear()
	var v := _call("remove", [key])
	return not v.begins_with("!")


func is_persistent() -> bool:
	return _persistent and bridge != null and bridge.available()


func kind() -> String:
	return "web"


## Calls helper method `fn` with `args` (JSON-encoded: valid JS literals). Returns the
## tagged answer; "!Unavailable" off the web or when the helper did not install.
func _call(fn: String, args: Array) -> String:
	if bridge == null or not bridge.available():
		last_error = "Unavailable"
		return "!" + last_error
	if not _installed:
		_installed = bridge.eval(HELPER_JS) is String
	var parts := PackedStringArray()
	for a: Variant in args:
		parts.append(JSON.stringify(a))
	var out: Variant = bridge.eval("window.%s.%s(%s)" % [HELPER, fn, ", ".join(parts)])
	if not (out is String):
		last_error = "NoAnswer"
		return "!" + last_error
	var s := out as String
	last_error = s.substr(1) if s.begins_with("!") else ""
	return s
