class_name VoicePool
extends Node
## A fixed pool of one-shot voices with a cap and priorities. Spec: Architecture rule 7
## ("audio players come from pools"); Audio. docs/AUDIO.md → Voice budget.
##
## Flat voices (AudioStreamPlayer: stingers, chimes, impacts) and positional voices
## (AudioStreamPlayer3D: whooshes, horns, hiss, scrapes) are created once in setup().
## play() / play_at() pick a free voice of the kind; when none is free, or `max_voices`
## are already playing across both kinds, the lowest-priority (then oldest) playing
## voice at or below the new sound's priority is stolen; otherwise the new sound drops.
## Nothing is allocated per play. A positional voice can follow a traffic car (the
## caller moves it through `track_slot` / `set_voice_position`).
##
## Test hook: `played` counts started sounds, `dropped` refused ones; the last
## LOG_SIZE ids and their process frames sit in a ring (log_id / log_frame).

const LOG_SIZE := 64
const NO_SLOT := -1

var max_voices: int = 16
var flat: Array[AudioStreamPlayer] = []
var positional: Array[AudioStreamPlayer3D] = []

## Started / refused sounds since setup (tests, dev).
var played: int = 0
var dropped: int = 0
var stolen: int = 0
## Ring of the last LOG_SIZE started sound ids and the process frame each started on.
var log_id: Array[StringName] = []
var log_frame := PackedInt64Array()
var log_count: int = 0

# Per voice: flat voices are 0..F-1, positional F..F+P-1.
var _priority := PackedInt32Array()
var _order := PackedInt64Array()
var _id: Array[StringName] = []
## Positional voices only (index - F): the traffic slot followed and its vehicle id,
## and the pitch before doppler.
var track_slot := PackedInt32Array()
var track_vehicle := PackedInt32Array()
var base_pitch := PackedFloat64Array()
var _seq: int = 0


## Builds the voices (once). `t` gives the counts and the 3D attenuation.
func setup(t: AudioTuning) -> void:
	if not flat.is_empty() or not positional.is_empty():
		return
	max_voices = t.max_voices
	for i in t.voices_flat:
		var p := AudioStreamPlayer.new()
		p.name = "Flat%d" % i
		add_child(p)
		flat.append(p)
	for i in t.voices_positional:
		var p := AudioStreamPlayer3D.new()
		p.name = "Pos%d" % i
		p.unit_size = t.positional_unit_size_m
		p.max_distance = t.positional_max_distance_m
		p.panning_strength = t.positional_panning
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED   # our own doppler
		add_child(p)
		positional.append(p)
	var n := flat.size() + positional.size()
	_priority.resize(n)
	_order.resize(n)
	_id.resize(n)
	track_slot.resize(positional.size())
	track_vehicle.resize(positional.size())
	base_pitch.resize(positional.size())
	for i in positional.size():
		track_slot[i] = NO_SLOT
		base_pitch[i] = 1.0
	log_id.resize(LOG_SIZE)
	log_frame.resize(LOG_SIZE)


func voice_count() -> int:
	return flat.size() + positional.size()


## Voices playing now.
func active_count() -> int:
	var n := 0
	for p in flat:
		if p.playing:
			n += 1
	for p in positional:
		if p.playing:
			n += 1
	return n


## A flat one-shot. Returns the voice index, or -1 when dropped.
func play(id: StringName, stream: AudioStream, bus: StringName, volume_db: float, pitch: float,
		priority: int) -> int:
	if stream == null:
		return -1
	var v := _pick(false, priority)
	if v < 0:
		dropped += 1
		return -1
	var p := flat[v]
	p.stop()
	p.stream = stream
	p.bus = bus
	p.volume_db = volume_db
	p.pitch_scale = pitch
	p.play()
	_started(v, id, priority)
	return v


## A positional one-shot at `pos` (render space), optionally following traffic `slot`
## (with its vehicle id) for placement and doppler: `pitch` is the base pitch, `doppler`
## the factor for now (TrafficAudio re-applies it per frame). Returns the voice index
## (flat voices first, so positional ones are >= flat.size()), or -1 when dropped.
func play_at(id: StringName, stream: AudioStream, bus: StringName, volume_db: float, pitch: float,
		priority: int, pos: Vector3, slot: int = NO_SLOT, vehicle_id: int = 0, doppler: float = 1.0) -> int:
	if stream == null:
		return -1
	var v := _pick(true, priority)
	if v < 0:
		dropped += 1
		return -1
	var k := v - flat.size()
	var p := positional[k]
	p.stop()
	p.stream = stream
	p.bus = bus
	p.volume_db = volume_db
	p.pitch_scale = pitch * doppler
	p.position = pos
	track_slot[k] = slot
	track_vehicle[k] = vehicle_id
	base_pitch[k] = pitch
	p.play()
	_started(v, id, priority)
	return v


## Stops every voice (run start, results).
func stop_all() -> void:
	for p in flat:
		p.stop()
	for i in positional.size():
		positional[i].stop()
		track_slot[i] = NO_SLOT


## The id of the sound started `back` plays ago (0 = the last one); &"" if none.
func last_id(back: int = 0) -> StringName:
	if back >= log_count or back >= LOG_SIZE:
		return &""
	return log_id[(log_count - 1 - back) % LOG_SIZE]


func last_frame(back: int = 0) -> int:
	if back >= log_count or back >= LOG_SIZE:
		return -1
	return log_frame[(log_count - 1 - back) % LOG_SIZE]


## How many of the last `window` started sounds had this id.
func count_recent(id: StringName, window: int = LOG_SIZE) -> int:
	var n := 0
	for b in mini(mini(window, log_count), LOG_SIZE):
		if log_id[(log_count - 1 - b) % LOG_SIZE] == id:
			n += 1
	return n


func _started(v: int, id: StringName, priority: int) -> void:
	_seq += 1
	_priority[v] = priority
	_order[v] = _seq
	_id[v] = id
	played += 1
	var r := log_count % LOG_SIZE
	log_id[r] = id
	log_frame[r] = Engine.get_process_frames()
	log_count += 1


func _playing(v: int) -> bool:
	if v < flat.size():
		return flat[v].playing
	return positional[v - flat.size()].playing


## A voice for a new sound of this kind and priority, or -1.
func _pick(want_positional: bool, priority: int) -> int:
	var lo := flat.size() if want_positional else 0
	var hi := voice_count() if want_positional else flat.size()
	if hi <= lo:
		return -1
	var free := -1
	for v in range(lo, hi):
		if not _playing(v):
			free = v
			break
	if free >= 0 and active_count() < max_voices:
		return free
	# Over the cap, or no free voice of this kind: steal. Over the cap the victim may be
	# of either kind (it frees budget), but the new sound still needs a voice of its kind.
	var victim := -1
	if free >= 0:
		victim = _weakest(0, voice_count(), priority)
		if victim < 0:
			return -1
		_stop(victim)
		stolen += 1
		return free
	victim = _weakest(lo, hi, priority)
	if victim < 0:
		return -1
	_stop(victim)
	stolen += 1
	return victim


## The playing voice in [lo, hi) with the lowest priority <= `priority` (oldest first).
func _weakest(lo: int, hi: int, priority: int) -> int:
	var best := -1
	for v in range(lo, hi):
		if not _playing(v) or _priority[v] > priority:
			continue
		if best < 0 or _priority[v] < _priority[best] \
				or (_priority[v] == _priority[best] and _order[v] < _order[best]):
			best = v
	return best


func _stop(v: int) -> void:
	if v < flat.size():
		flat[v].stop()
	else:
		var k := v - flat.size()
		positional[k].stop()
		track_slot[k] = NO_SLOT
