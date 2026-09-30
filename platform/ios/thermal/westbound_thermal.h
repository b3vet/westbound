// WestboundThermal: iOS thermal state for the adaptive governor (WP9.1).
// Spec: Tech stack -> Platform services ("A small native plugin per platform reports
// thermal state (iOS ProcessInfo.thermalState ...) to the governor"). docs/QUALITY.md.
//
// UNTESTED ON DEVICE. Written against the Godot 4.x iOS plugin API (.gdip + static
// library, engine headers); build and install steps in docs/QUALITY.md -> Native plugins.
//
// GDScript interface (src/platform/thermal.gd reads it through Engine.get_singleton):
//   get_raw_state() -> int     NSProcessInfo.thermalState: 0 nominal, 1 fair, 2 serious,
//                              3 critical
//   get_platform() -> String   "ios"
//   is_supported() -> bool     true (iOS 11+)
//   signal thermal_state_changed(raw_state: int)   on
//                              NSProcessInfoThermalStateDidChangeNotification, emitted on
//                              the engine's main loop (deferred)

#pragma once

#include "core/object/class_db.h"
#include "core/object/object.h"

class WestboundThermal : public Object {
	GDCLASS(WestboundThermal, Object);

	static WestboundThermal *singleton;
	// The NSNotificationCenter observer token (an Objective-C object, retained).
	void *observer = nullptr;

protected:
	static void _bind_methods();

public:
	static WestboundThermal *get_singleton();

	int get_raw_state() const;
	String get_platform() const;
	bool is_supported() const;
	// Emits thermal_state_changed with the current state (called deferred).
	void notify_changed();

	WestboundThermal();
	~WestboundThermal();
};
