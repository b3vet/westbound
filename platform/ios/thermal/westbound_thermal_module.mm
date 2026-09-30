// WestboundThermal plugin entry points (named in westbound_thermal.gdip). Registers the
// engine singleton "WestboundThermal" that src/platform/thermal.gd looks for.
// UNTESTED ON DEVICE.

#include "westbound_thermal.h"

#include "core/config/engine.h"

static WestboundThermal *westbound_thermal = nullptr;

void westbound_thermal_init() {
	westbound_thermal = memnew(WestboundThermal);
	Engine::get_singleton()->add_singleton(Engine::Singleton("WestboundThermal", westbound_thermal));
}

void westbound_thermal_deinit() {
	if (westbound_thermal != nullptr) {
		memdelete(westbound_thermal);
		westbound_thermal = nullptr;
	}
}
