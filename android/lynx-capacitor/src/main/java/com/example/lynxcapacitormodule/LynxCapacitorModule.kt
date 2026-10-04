package com.example.lynxcapacitormodule

import android.content.Context
import com.lynx.jsbridge.LynxMethod
import com.lynx.jsbridge.LynxModule
import com.lynx.react.bridge.Callback
import com.lynx.react.bridge.JavaOnlyArray
import com.lynx.tasm.behavior.LynxContext
import java.lang.ref.WeakReference

/** LynxShell 显式注册的唯一原生能力 Module；底层调用直接进入 Android dispatcher。 */
class LynxCapacitorModule(context: Context) : LynxModule(context) {
    private val eventSender: (String) -> Unit = createEventSender(context)

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
        LynxCapacitorRuntime.handleCall(payload, callback, mContext)
    }

    override fun destroy() {
        LynxCapacitorRuntime.destroyForContext(mContext, eventSender)
        super.destroy()
    }

    companion object {
        /** 闭包只捕获局部弱引用，避免 Runtime 的 WeakHashMap value 反向强持有 Module/Context。 */
        private fun createEventSender(context: Context): (String) -> Unit {
            val owner = WeakReference(context as? LynxContext)
            return { resultJson -> owner.get()?.sendGlobalEvent(RESULT_EVENT, JavaOnlyArray.of(resultJson)) }
        }

        const val RESULT_EVENT = "lynx-capacitor-result"
        const val MODULE_NAME = "LynxCapacitorModule"
    }
}
