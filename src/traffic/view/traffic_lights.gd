class_name TrafficLights
extends RefCounted
# lint: not-sim render-side helper for the traffic view (pure functions, no simulation)
## Which lamps of a traffic vehicle are lit, from its TrafficState flags. Spec:
## Traffic → Visuals (brake lights, blinkers, hazards, headlights and taillights);
## Lives → Fairness rules 1 and 3 (blinkers before every lane change, brake lights on
## every deceleration above 1 m/s², brighter above 4 m/s²); Cameras → Glare rule
## (taillights and brake lights always emissive); owner decision D8 (no high beams).
##
## The result is a small bit set per vehicle that the traffic shader reads from the
## instance custom data (BIT_* here = BIT_* in traffic.gdshader), plus the glow sprite
## kinds (KIND_* = glow.gdshader's table). All functions are static and allocation-free.

## Mesh parts (vertex UV.x of traffic models; traffic.gdshader PART_*).
const PART_FIXED := 0
const PART_PAINT := 1
const PART_GLASS := 2
const PART_WHEEL := 3
const PART_HEAD := 4
const PART_REAR := 5             ## tail lamps: always lit (glare rule), brake-bright when braking
const PART_BRAKE := 6            ## brake-only (high-mounted third brake light)
const PART_BLINK_L := 7
const PART_BLINK_R := 8
const PART_COUNT := 9

const BIT_BRAKE := 1
const BIT_BRAKE_STRONG := 2
const BIT_BLINK_L := 4           ## left blinker lamps lit this instant (flash phase on)
const BIT_BLINK_R := 8
const BIT_HEAD := 16             ## headlights on (and tail lamps at night brightness)
## Paint slot multiplier in the packed custom value (bits < 32).
const PALETTE_STRIDE := 32
const PALETTE_SHIFT := 5
## Packed values stay integers below 2048 so 16-bit floats (Compatibility) keep them exact.
const PALETTE_SLOTS := 64

## Blinker mask (which sides flash): left, right. Hazards flash both.
const MASK_L := 1
const MASK_R := 2

## Glow sprite kinds (glow.gdshader kind_color / kind_size index).
const KIND_OFF := 0
const KIND_HEAD := 1
const KIND_TAIL := 2
const KIND_BRAKE := 3
const KIND_BRAKE_STRONG := 4
const KIND_BLINKER := 5
const KIND_COUNT := 6
## Glow instance code: kind_l + GLOW_KIND_STRIDE * kind_r + GLOW_FRONT for a front pair.
const GLOW_KIND_STRIDE := 8
const GLOW_FRONT := 64


## Sides that flash for these flags (MASK_L | MASK_R); hazards flash both.
static func blink_mask(flags: int) -> int:
	var m := 0
	if (flags & (TrafficState.FLAG_BLINKER_LEFT | TrafficState.FLAG_HAZARD)) != 0:
		m |= MASK_L
	if (flags & (TrafficState.FLAG_BLINKER_RIGHT | TrafficState.FLAG_HAZARD)) != 0:
		m |= MASK_R
	return m


## Flash phase: lit for the first `duty` of every 1 / hz cycle since the blinker started.
static func blink_lit(elapsed_s: float, hz: float, duty: float) -> bool:
	if elapsed_s < 0.0:
		return false
	return fposmod(elapsed_s * hz, 1.0) < duty


## Lamp bits for a vehicle. `mask` is its current blink_mask, `blink_elapsed_s` the time
## since that mask last changed (the first flash is immediate). FLAG_HIGH_BEAM is
## ignored (owner decision D8).
static func bits(flags: int, mask: int, blink_elapsed_s: float, hz: float, duty: float) -> int:
	var b := 0
	if (flags & TrafficState.FLAG_BRAKE) != 0:
		b |= BIT_BRAKE
	if (flags & TrafficState.FLAG_BRAKE_STRONG) != 0:
		b |= BIT_BRAKE | BIT_BRAKE_STRONG
	if (flags & TrafficState.FLAG_HEADLIGHTS) != 0:
		b |= BIT_HEAD
	if mask != 0 and blink_lit(blink_elapsed_s, hz, duty):
		if (mask & MASK_L) != 0:
			b |= BIT_BLINK_L
		if (mask & MASK_R) != 0:
			b |= BIT_BLINK_R
	return b


## Instance custom value: bits + 32 * paint slot (an exact small integer as a float).
static func pack(lamp_bits: int, paint_slot: int) -> float:
	return float(lamp_bits + PALETTE_STRIDE * clampi(paint_slot, 0, PALETTE_SLOTS - 1))


static func unpack_bits(packed: float) -> int:
	return roundi(packed) % PALETTE_STRIDE


static func unpack_slot(packed: float) -> int:
	return roundi(packed) >> PALETTE_SHIFT


## Glow kind of a rear lamp on one side (`blink_bit` = BIT_BLINK_L or BIT_BLINK_R).
## Blinker > strong brake > brake > tail (with headlights, or by day if `day_tail`).
static func rear_kind(lamp_bits: int, blink_bit: int, day_tail: bool) -> int:
	if (lamp_bits & blink_bit) != 0:
		return KIND_BLINKER
	if (lamp_bits & BIT_BRAKE_STRONG) != 0:
		return KIND_BRAKE_STRONG
	if (lamp_bits & BIT_BRAKE) != 0:
		return KIND_BRAKE
	if (lamp_bits & BIT_HEAD) != 0 or day_tail:
		return KIND_TAIL
	return KIND_OFF


## Glow instance code (glow.gdshader INSTANCE_CUSTOM.r) for a lamp pair.
static func glow_code(kind_l: int, kind_r: int, front: bool) -> float:
	return float(kind_l + GLOW_KIND_STRIDE * kind_r + (GLOW_FRONT if front else 0))


## Glow kind of a front lamp on one side: blinker > headlight.
static func front_kind(lamp_bits: int, blink_bit: int) -> int:
	if (lamp_bits & blink_bit) != 0:
		return KIND_BLINKER
	if (lamp_bits & BIT_HEAD) != 0:
		return KIND_HEAD
	return KIND_OFF
