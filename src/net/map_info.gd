class_name MapInfo
extends RefCounted
## The map a client joins rooms with (N3.2): its road-space file and the hash `Hello`
## carries. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → The loop map ("Hash check on join:
## client and server compare map hashes when joining a room, and a mismatch is refused
## with a 'please update' message"); docs/PROTOCOL.md (map_hash = the raw SHA-256 of the
## road-space file); docs/LOOP_MAP.md.
##
##   client.start(url, build, MapInfo.loop_hash(), token)   # NetClient's Hello
##
## The hash is the SHA-256 of every byte of `res://data/maps/loop_v1.json` as packed in
## this build (FileAccess.get_sha256), so a build that shipped a different file joins
## nothing. Exports must ship the JSON byte for byte: every preset exports all resources
## (JSON included, unconverted); the web export smoke checks the hash the build prints.

const LOOP_V1_PATH := "res://data/maps/loop_v1.json"
const LOOP_V1_ID := &"loop_v1"

static var _hex_cache: Dictionary = {}


## SHA-256 of the file at `path`, 64 lowercase hex characters ("" when it is missing).
## Cached per path (the file never changes in a build).
static func hash_hex(path: String = LOOP_V1_PATH) -> String:
	if not _hex_cache.has(path):
		_hex_cache[path] = FileAccess.get_sha256(path) if FileAccess.file_exists(path) else ""
	return _hex_cache[path]


## The same as the 32 raw bytes `Hello.map_hash` carries (empty when the file is missing).
static func hash_bytes(path: String = LOOP_V1_PATH) -> PackedByteArray:
	var hex := hash_hex(path)
	return NetCodec.hex_to_bytes(hex) if hex.length() == NetCodec.MAP_HASH_LEN * 2 else PackedByteArray()


## `loop_v1`'s hash bytes (what NetClient.start sends).
static func loop_hash() -> PackedByteArray:
	return hash_bytes(LOOP_V1_PATH)
