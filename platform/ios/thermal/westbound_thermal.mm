// WestboundThermal: iOS thermal state (see westbound_thermal.h). UNTESTED ON DEVICE.
// Compile with -fobjc-arc (build.sh does).

#include "westbound_thermal.h"

#import <Foundation/Foundation.h>

WestboundThermal *WestboundThermal::singleton = nullptr;

void WestboundThermal::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_raw_state"), &WestboundThermal::get_raw_state);
	ClassDB::bind_method(D_METHOD("get_platform"), &WestboundThermal::get_platform);
	ClassDB::bind_method(D_METHOD("is_supported"), &WestboundThermal::is_supported);
	ClassDB::bind_method(D_METHOD("notify_changed"), &WestboundThermal::notify_changed);
	ADD_SIGNAL(MethodInfo("thermal_state_changed", PropertyInfo(Variant::INT, "raw_state")));
}

WestboundThermal *WestboundThermal::get_singleton() {
	return singleton;
}

int WestboundThermal::get_raw_state() const {
	// NSProcessInfoThermalStateNominal = 0, Fair = 1, Serious = 2, Critical = 3.
	return (int)[[NSProcessInfo processInfo] thermalState];
}

String WestboundThermal::get_platform() const {
	return "ios";
}

bool WestboundThermal::is_supported() const {
	return true;
}

void WestboundThermal::notify_changed() {
	emit_signal(SNAME("thermal_state_changed"), get_raw_state());
}

WestboundThermal::WestboundThermal() {
	singleton = this;
	// The notification can arrive on any thread; the main queue hands it to the main
	// thread, and call_deferred emits it inside the engine's frame, not the UIKit callback.
	id token = [[NSNotificationCenter defaultCenter]
			addObserverForName:NSProcessInfoThermalStateDidChangeNotification
						object:nil
						 queue:[NSOperationQueue mainQueue]
					usingBlock:^(NSNotification *note) {
						WestboundThermal *self_ref = WestboundThermal::get_singleton();
						if (self_ref != nullptr) {
							self_ref->call_deferred(SNAME("notify_changed"));
						}
					}];
	observer = (__bridge_retained void *)token;
}

WestboundThermal::~WestboundThermal() {
	if (observer != nullptr) {
		id token = (__bridge_transfer id)observer;
		[[NSNotificationCenter defaultCenter] removeObserver:token];
		observer = nullptr;
	}
	if (singleton == this) {
		singleton = nullptr;
	}
}
