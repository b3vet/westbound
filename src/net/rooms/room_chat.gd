class_name NetRoomChat
extends RefCounted
## Quick chat: the preset phrases, the horn and the emotes, as protocol items and player
## text. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Rooms, parties and matchmaking → Quick
## chat ("A small wheel of preset phrases: 'nice thread', 'follow me', 'slow down',
## 'regroup', 'gg', 'one more lap'. Plus a horn and a few emotes shown on the nametag.
## Rate-limited, and muted per player from the room menu"); "Chat: no free text";
## docs/PROTOCOL.md §4 (chat item kinds: phrase, horn, emote 0–31). WP N5.2.

## Phrase texts, in NetCodec.PHRASE order.
const PHRASE_TEXT: Array[String] = ["NICE THREAD", "FOLLOW ME", "SLOW DOWN", "REGROUP", "GG", "ONE MORE LAP"]
const HORN_TEXT := "HONK!"
## The emotes this build offers (ids 0..n-1 of the protocol's 0–31); an unknown id from a
## newer build shows as EMOTE_UNKNOWN.
const EMOTE_TEXT: Array[String] = ["WAVE", "THUMBS UP", "FIRE", "SALUTE", "WOW", "LOL"]
const EMOTE_FORMAT := "* %s *"
const EMOTE_UNKNOWN := "* EMOTE *"

const KIND_PHRASE := "phrase"
const KIND_HORN := "horn"
const KIND_EMOTE := "emote"


static func phrase_item(index: int) -> Dictionary:
	return {"kind": KIND_PHRASE, "phrase": NetCodec.PHRASE[clampi(index, 0, NetCodec.PHRASE.size() - 1)]}


static func horn_item() -> Dictionary:
	return {"kind": KIND_HORN}


static func emote_item(index: int) -> Dictionary:
	return {"kind": KIND_EMOTE, "emote": clampi(index, 0, NetCodec.MAX_EMOTE)}


## The text a chat item shows (feed and nametag).
static func text_of(item: Dictionary) -> String:
	match String(item.get("kind", "")):
		KIND_PHRASE:
			var i := NetCodec.PHRASE.find(String(item.get("phrase", "")))
			return PHRASE_TEXT[i] if i >= 0 and i < PHRASE_TEXT.size() else ""
		KIND_HORN:
			return HORN_TEXT
		KIND_EMOTE:
			var e := int(item.get("emote", -1))
			return EMOTE_FORMAT % EMOTE_TEXT[e] if e >= 0 and e < EMOTE_TEXT.size() else EMOTE_UNKNOWN
	return ""
