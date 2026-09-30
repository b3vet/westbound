@tool
extends EditorPlugin
## Android plugin v2 packaging for WestboundThermal (WP9.1; docs/QUALITY.md → Native
## plugins). UNTESTED ON DEVICE. A template: copy this folder to res://addons/westbound_thermal/,
## put the built AARs in its bin/ folder (bin/westbound_thermal-debug.aar and
## bin/westbound_thermal-release.aar), and enable the plugin in the project settings. The
## export then adds the AAR to Android builds; at run time src/platform/thermal.gd finds the
## `WestboundThermal` singleton.

const AAR_DEBUG := "westbound_thermal/bin/westbound_thermal-debug.aar"
const AAR_RELEASE := "westbound_thermal/bin/westbound_thermal-release.aar"

var _export: AndroidExport


func _enter_tree() -> void:
	_export = AndroidExport.new()
	add_export_plugin(_export)


func _exit_tree() -> void:
	remove_export_plugin(_export)
	_export = null


class AndroidExport extends EditorExportPlugin:
	func _get_name() -> String:
		return "WestboundThermal"

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	## Paths are relative to res://addons/.
	func _get_android_libraries(_platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
		return PackedStringArray([AAR_DEBUG if debug else AAR_RELEASE])
