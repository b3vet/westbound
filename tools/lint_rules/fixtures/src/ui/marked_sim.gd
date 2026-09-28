extends RefCounted
# lint: sim
## Not in a sim path, but the marker opts it into the sim rules.


func roll() -> float:
	return randf() * 3.0 # expect: WB102, WB101
