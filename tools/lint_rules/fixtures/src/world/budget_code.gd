extends Node3D
## Rendering-budget violations made from code. "OmniLight3D" in a string is fine.


func _ready() -> void:
	var lamp := OmniLight3D.new() # expect: WB001
	add_child(lamp)
	var mat := StandardMaterial3D.new() # expect: WB002
	$Sun.shadow_enabled = true # expect: WB003
	$Sun.shadow_enabled = false
	var env := Environment.new()
	env.glow_enabled = true # expect: WB004
	env.set_ssil_enabled(true) # expect: WB004
	env.volumetric_fog_enabled = false
	print("OmniLight3D shadow_enabled = true", mat)
