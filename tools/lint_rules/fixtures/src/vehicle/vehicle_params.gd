extends RefCounted
## Not a sim file for the other rules (numbers are fine here), but WB105 covers it.


func build(slip_deg: float) -> float:
	return tan(deg_to_rad(slip_deg)) * 12.5 # expect: WB105
