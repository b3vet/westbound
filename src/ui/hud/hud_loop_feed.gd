class_name HudLoopFeed
extends RefCounted
## Per-frame HUD values of the loop test mode (N3.2) and, later, multiplayer rooms (N5):
## the room clock and the sector. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Time of day in
## multiplayer ("HUD: the sun bar is replaced by a small clock showing time until night
## or dawn"), Scoring in multiplayer (sectors replace checkpoints). docs/HUD.md.
##
## The run fills it once per frame (RunLoop.fill_feed) next to the HudFeed; the HUD
## reads it when bound (`hud.bind_loop(feed)`): the top-centre plate shows the clock and
## the distance to the next sector gantry instead of the sun and the next checkpoint, and
## the crossing toast names sectors. Display data only.

## False: not a loop run (the HUD shows the sun bar).
var active: bool = false
## Where in the room's cycle (0 = the day starts, 1 = the next day) and the day's share.
var cycle_frac: float = 0.0
var day_frac: float = 1.0
## Night (points ×2) and the seconds until the night (by day) or the day (at night).
var night: bool = false
var flip_in_s: float = 0.0
## Metres to the next sector gantry (negative: none planned).
var sector_distance_m: float = -1.0
## The lap (unwrapped: lap 1 is the first) and the sector (1-based) the player is in.
var lap: int = 1
var sector: int = 1
var sectors: int = 6


func reset() -> void:
	active = false
	cycle_frac = 0.0
	day_frac = 1.0
	night = false
	flip_in_s = 0.0
	sector_distance_m = -1.0
	lap = 1
	sector = 1
