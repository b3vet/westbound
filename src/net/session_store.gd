class_name NetSessionStore
extends RefCounted
## Where the session's account lives between launches: the account id, the device secret,
## the refresh token and the cached profile, as one small Dictionary. Spec: multiplayer
## handoff → Accounts and authentication (device secret storage); plan MP-D2. WP N1.2;
## docs/NET_CLIENT.md → Storage.
##
## Implementations: NetFileStore (native: an encrypted user:// file), NetWebStore (web:
## localStorage) and this in-memory base (tests, previews, and the fallback when the
## platform store cannot write, e.g. Safari private mode). MP-D2: the iOS Keychain and
## Android Keystore plugins replace NetFileStore later, behind this same interface.
## Implementations never log the contents.

var _mem: Dictionary = {}
## Writes that reached the store (tests).
var writes: int = 0


## The stored document ({} when nothing is stored or it cannot be read).
func load_data() -> Dictionary:
	return _mem.duplicate(true)


## Replaces the stored document. False when it could not be written.
func save_data(doc: Dictionary) -> bool:
	_mem = doc.duplicate(true)
	writes += 1
	return true


## Removes everything stored. False when it could not be removed.
func clear() -> bool:
	_mem = {}
	writes += 1
	return true


## False when this store cannot keep anything across launches (the session then keeps
## the account for this launch only and says so).
func is_persistent() -> bool:
	return false


## "file", "web", "memory" (dev report, tests).
func kind() -> String:
	return "memory"
