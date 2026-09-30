extends WBTest
## MapInfo (N3.2): the map hash a client sends in Hello. Spec:
## WESTBOUND_MULTIPLAYER_HANDOFF.md → The loop map ("Hash check on join"); docs/PROTOCOL.md
## (map_hash = the raw SHA-256 of the road-space file); docs/LOOP_MAP.md.

const SIDECAR := "res://data/maps/loop_v1.sha256"


func test_loop_hash_is_the_committed_sidecar() -> void:
	var hex := MapInfo.hash_hex()
	eq(hex.length(), 64, "64 hex characters")
	var sidecar := FileAccess.get_file_as_string(SIDECAR).split(" ", false)[0]
	eq(hex, sidecar, "SHA-256 of res://data/maps/loop_v1.json = the committed .sha256")
	eq(hex, LoopExport.sha256_hex(FileAccess.get_file_as_string(MapInfo.LOOP_V1_PATH)), "LoopExport agrees")


func test_hello_bytes() -> void:
	var raw := MapInfo.loop_hash()
	eq(raw.size(), NetCodec.MAP_HASH_LEN, "32 raw bytes for Hello")
	eq(raw.hex_encode(), MapInfo.hash_hex())


func test_missing_file_has_no_hash() -> void:
	eq(MapInfo.hash_hex("res://data/maps/no_such_map.json"), "")
	eq(MapInfo.hash_bytes("res://data/maps/no_such_map.json").size(), 0)
