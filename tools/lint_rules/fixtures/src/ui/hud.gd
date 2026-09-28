extends Control
## Not a sim file: numbers and randf() are fine here; return types still matter.

const FLASH := 0.35


func _ready(): # expect: WB201
	var jitter := randf() * 4.0
	var cb := func(x): return x * 2.0
	print(jitter, cb.call(3))


static func format_score(points: int,
		multiplier: float) -> String:
	return "%d x%.1f" % [points, multiplier]


func show_toast(text: String, # expect: WB201
		seconds: float):
	print(text, seconds)
