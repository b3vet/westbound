class_name NetFileStore
extends NetSessionStore
## Native session storage: one JSON document in an encrypted user:// file
## (FileAccess.open_encrypted_with_pass, AES-256). Spec: multiplayer handoff → Accounts
## (device secret storage); plan MP-D2 ("native builds use an encrypted user:// file
## until the Keychain plugin lands"). WP N1.2; docs/NET_CLIENT.md → Storage.
##
## The key is per install: SHA-256 of a random salt made on first use (its own user://
## file) and, on phones, OS.get_unique_id(). So a copied session file does not open on
## another device, and nothing secret is in the game package. It is obfuscation against
## casual copying, not protection from someone with the unlocked device: that is what
## the Keychain / Android Keystore plugins bring (MP-D2). Writes go to a temporary file
## that is then renamed over the old one, so a crash mid-write keeps the old document.

const DIR := "user://net"
const SALT_PATH := "user://net/install.salt"
const SALT_BYTES := 32
const TMP_SUFFIX := ".tmp"

var path: String
var salt_path: String


## `name` selects the document (one per server: see NetSession.store_name()).
func _init(file_name: String = "session", dir: String = DIR, salt_file: String = SALT_PATH) -> void:
	path = "%s/%s.dat" % [dir, file_name]
	salt_path = salt_file


func load_data() -> Dictionary:
	if not FileAccess.file_exists(path) or not FileAccess.file_exists(salt_path):
		return {}
	var f := FileAccess.open_encrypted_with_pass(path, FileAccess.READ, _key())
	if f == null:
		push_warning("NetFileStore: the session file cannot be opened (%s); starting fresh"
				% error_string(FileAccess.get_open_error()))
		return {}
	var text := f.get_as_text()
	f.close()
	var j := JSON.new()
	if j.parse(text) != OK or not (j.data is Dictionary):
		push_warning("NetFileStore: the session file is not a JSON object; starting fresh")
		return {}
	return j.data as Dictionary


func save_data(doc: Dictionary) -> bool:
	if not _ensure_dir():
		return false
	var tmp := path + TMP_SUFFIX
	var f := FileAccess.open_encrypted_with_pass(tmp, FileAccess.WRITE, _key())
	if f == null:
		push_warning("NetFileStore: cannot write the session file (%s)"
				% error_string(FileAccess.get_open_error()))
		return false
	f.store_string(JSON.stringify(doc))
	f.close()
	var err := DirAccess.rename_absolute(tmp, path)
	if err != OK:
		push_warning("NetFileStore: cannot replace the session file (%s)" % error_string(err))
		return false
	writes += 1
	return true


func clear() -> bool:
	writes += 1
	if not FileAccess.file_exists(path):
		return true
	return DirAccess.remove_absolute(path) == OK


func is_persistent() -> bool:
	return true


func kind() -> String:
	return "file"


func _ensure_dir() -> bool:
	var dir := path.get_base_dir()
	if DirAccess.dir_exists_absolute(dir):
		return true
	return DirAccess.make_dir_recursive_absolute(dir) == OK


## The per-install key (makes the salt on first use).
func _key() -> String:
	var salt := ""
	if FileAccess.file_exists(salt_path):
		salt = FileAccess.get_file_as_string(salt_path).strip_edges()
	if salt.is_empty():
		salt = Crypto.new().generate_random_bytes(SALT_BYTES).hex_encode()
		if _ensure_dir_of(salt_path):
			var f := FileAccess.open(salt_path, FileAccess.WRITE)
			if f != null:
				f.store_string(salt)
				f.close()
	var device := OS.get_unique_id() if OS.has_feature("mobile") else ""
	return (salt + ":" + device).sha256_text()


static func _ensure_dir_of(file_path: String) -> bool:
	var dir := file_path.get_base_dir()
	return DirAccess.dir_exists_absolute(dir) or DirAccess.make_dir_recursive_absolute(dir) == OK
