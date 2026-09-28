class_name Thermal
extends RefCounted
## Device thermal state source. Spec: Tech stack → Platform services (native
## thermal plugin) and Performance budget → Adaptive governor.
##
## WP0.3 stub: always reports nominal. WP9.1 replaces the body with the native
## plugins (iOS `ProcessInfo.thermalState`, Android
## `PowerManager.getCurrentThermalStatus`) mapped onto the four states below.

const NOMINAL := &"nominal"
const FAIR := &"fair"
const SERIOUS := &"serious"
const CRITICAL := &"critical"


## One of NOMINAL, FAIR, SERIOUS, CRITICAL.
func get_state() -> StringName:
	return NOMINAL
