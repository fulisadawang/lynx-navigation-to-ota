package com.example.lynxshell.bridge

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.example.lynxshell.LynxShell
import com.lynx.jsbridge.Arguments
import com.lynx.react.bridge.Callback
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONArray
import org.json.JSONObject

/** 保留 Shell 五个旧方法的 ABI，执行与 owner 生命周期交给宿主安装的统一媒体 backend。 */
internal object ShellMediaBridge {
    private val mainHandler = Handler(Looper.getMainLooper())

    fun call(context: Context, methodName: String, optionsJSON: String, callback: Callback) {
        val host = LynxShell.nativeMediaHost()
        if (host == null) {
            invoke(callback, failure("宿主未安装原生媒体能力"))
            return
        }
        val delivered = AtomicBoolean(false)
        val complete: (JSONObject) -> Unit = { result ->
            if (delivered.compareAndSet(false, true)) invoke(callback, result)
        }
        try {
            host.call(context, methodName, optionsJSON, complete)
        } catch (error: Exception) {
            if (delivered.get()) throw error
            complete(failure(error.message ?: "原生媒体调用失败"))
        }
    }

    private fun failure(message: String): JSONObject = JSONObject().put("code", -1).put("msg", message)

    private fun invoke(callback: Callback, result: JSONObject) {
        val value = Arguments.makeNativeMap(bridgeObject(result))
        if (Looper.myLooper() == Looper.getMainLooper()) callback.invoke(value)
        else mainHandler.post { callback.invoke(value) }
    }

    private fun bridgeObject(value: JSONObject): HashMap<String, Any?> = hashMapOf<String, Any?>().apply {
        value.keys().forEach { key -> put(key, bridgeValue(value.opt(key))) }
    }

    private fun bridgeValue(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> bridgeObject(value)
        is JSONArray -> arrayListOf<Any?>().apply {
            for (index in 0 until value.length()) add(bridgeValue(value.opt(index)))
        }
        else -> value
    }
}
