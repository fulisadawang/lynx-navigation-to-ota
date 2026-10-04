package com.example.lynxcapacitormodule

import android.content.Context
import org.json.JSONObject

/** composition root 把真实 Shell 容器适配进来，能力 Module 不依赖 Shell AAR。 */
interface LynxCapacitorHostProvider {
    val supportedMethods: Set<String>
    fun resolve(callerContext: Context): LynxCapacitorHost?
    fun release(callerContext: Context)
}

interface LynxCapacitorHost {
    fun call(pluginId: String, methodName: String, options: JSONObject, complete: (JSONObject) -> Unit)
}

internal object NativeHostRegistry {
    @Volatile var provider: LynxCapacitorHostProvider? = null
    @Volatile var supportedMethods: Set<String> = emptySet()
    fun install(provider: LynxCapacitorHostProvider?) {
        supportedMethods = provider?.supportedMethods?.toSet() ?: emptySet()
        this.provider = provider
    }
    fun requiresHost(pluginId: String, methodName: String): Boolean =
        (pluginId in setOf("StatusBar", "SystemBars", "SafeArea", "ScreenOrientation") ||
            (pluginId == "TextZoom" && methodName in setOf("get", "set"))) &&
            !(pluginId == "StatusBar" && methodName == "getInfo") &&
            !(pluginId == "ScreenOrientation" && methodName == "orientation")
}
