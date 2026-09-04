package com.example.lynxcapacitormodule

import android.content.Context
import com.lynx.jsbridge.LynxMethod
import com.lynx.jsbridge.LynxModule
import com.lynx.react.bridge.Callback
import com.lynx.react.bridge.JavaOnlyArray
import com.lynx.tasm.behavior.LynxContext

/** LynxShell 显式注册的唯一原生能力 Module；底层调用直接进入 Android dispatcher。 */
class LynxCapacitorModule(context: Context) : LynxModule(context) {
    private val eventSender: (String) -> Unit = { resultJson ->
        (context as? LynxContext)?.sendGlobalEvent(
            RESULT_EVENT,
            JavaOnlyArray.of(resultJson),
        )
    }

    init {
        LynxCapacitorRuntime.setEventSender(context, eventSender)
    }

    @LynxMethod
    fun getPlatform(): String = "android"

    @LynxMethod
    fun getPluginHeaders(): String = LynxCapacitorRuntime.pluginHeaders()

    @LynxMethod
    fun getCapabilityStatus(): String = LynxCapacitorRuntime.capabilityStatus()

    @LynxMethod
    fun handleCall(payload: String, callback: Callback) {
        LynxCapacitorRuntime.handleCall(payload, callback)
    }

    override fun destroy() {
        LynxCapacitorRuntime.clearEventSender(eventSender)
    }

    companion object {
        const val RESULT_EVENT = "lynx-capacitor-result"
        const val MODULE_NAME = "LynxCapacitorModule"
    }
}
