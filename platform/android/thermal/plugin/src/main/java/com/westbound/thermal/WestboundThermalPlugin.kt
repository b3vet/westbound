// WestboundThermal: Android thermal status for the adaptive governor (WP9.1).
// Spec: Tech stack -> Platform services ("A small native plugin per platform reports
// thermal state (... Android PowerManager.getCurrentThermalStatus) to the governor").
// docs/QUALITY.md -> Native plugins.
//
// UNTESTED ON DEVICE. A Godot Android plugin (v2: an AAR registered through the
// AndroidManifest meta-data, packaged by the addon's EditorExportPlugin).
//
// GDScript interface (src/platform/thermal.gd reads it through Engine.get_singleton):
//   get_raw_state() -> int     PowerManager.getCurrentThermalStatus(): THERMAL_STATUS_NONE 0,
//                              LIGHT 1, MODERATE 2, SEVERE 3, CRITICAL 4, EMERGENCY 5,
//                              SHUTDOWN 6; -1 below Android 10 (API 29)
//   get_platform() -> String   "android"
//   is_supported() -> bool     API 29+ with a PowerManager
//   signal thermal_state_changed(raw_state: int)   from OnThermalStatusChangedListener,
//                              emitted on the render (engine) thread
@file:Suppress("FunctionName")

package com.westbound.thermal

import android.content.Context
import android.os.Build
import android.os.PowerManager
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot

class WestboundThermalPlugin(godot: Godot) : GodotPlugin(godot) {

    private val stateChanged = SignalInfo("thermal_state_changed", Int::class.javaObjectType)
    private var listener: Any? = null   // PowerManager.OnThermalStatusChangedListener (API 29+)

    private val powerManager: PowerManager?
        get() = activity?.getSystemService(Context.POWER_SERVICE) as? PowerManager

    override fun getPluginName(): String = "WestboundThermal"

    override fun getPluginSignals(): Set<SignalInfo> = setOf(stateChanged)

    @UsedByGodot
    fun get_raw_state(): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return -1
        return powerManager?.currentThermalStatus ?: -1
    }

    @UsedByGodot
    fun get_platform(): String = "android"

    @UsedByGodot
    fun is_supported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && powerManager != null

    override fun onMainResume() {
        super.onMainResume()
        register()
    }

    override fun onMainPause() {
        super.onMainPause()
        unregister()
    }

    override fun onMainDestroy() {
        unregister()
        super.onMainDestroy()
    }

    private fun register() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || listener != null) return
        val pm = powerManager ?: return
        val l = PowerManager.OnThermalStatusChangedListener { status ->
            // Called on the main (UI) thread; hand it to the engine's thread.
            runOnRenderThread { emitSignal(stateChanged.name, status) }
        }
        pm.addThermalStatusListener(l)
        listener = l
        // The state may have changed while paused: report it now.
        val now = pm.currentThermalStatus
        runOnRenderThread { emitSignal(stateChanged.name, now) }
    }

    private fun unregister() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val l = listener as? PowerManager.OnThermalStatusChangedListener ?: return
        powerManager?.removeThermalStatusListener(l)
        listener = null
    }
}
