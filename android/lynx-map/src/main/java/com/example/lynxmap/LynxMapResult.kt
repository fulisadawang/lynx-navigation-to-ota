package com.example.lynxmap

import com.lynx.react.bridge.JavaOnlyMap
import com.lynx.jsbridge.Arguments

internal object LynxMapResult {
    fun success(message: String, data: Map<String, Any> = emptyMap()): JavaOnlyMap =
        Arguments.makeNativeMap(hashMapOf("code" to 0, "message" to message, "data" to data))

    fun error(code: Int, message: String): JavaOnlyMap =
        Arguments.makeNativeMap(hashMapOf("code" to code, "message" to message, "data" to emptyMap<String, Any>()))

    fun invalid(message: String): JavaOnlyMap = JavaOnlyMap().apply {
        putInt("code", 1001)
        putString("reasonCode", "INVALID_ARGUMENT")
        putString("message", message)
    }

    fun unsupported(capability: String): JavaOnlyMap = JavaOnlyMap().apply {
        putInt("code", 1004)
        putString("reasonCode", "UNSUPPORTED")
        putString("capability", capability)
        putString("message", "Android 地图能力尚未接通")
    }
}
