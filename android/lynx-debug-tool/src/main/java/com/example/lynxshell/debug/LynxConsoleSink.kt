package com.example.lynxshell.debug

import com.lynx.devtoolwrapper.LynxInspectorConsoleDelegate
import com.lynx.tasm.LynxView
import org.json.JSONArray
import org.json.JSONObject
import java.util.WeakHashMap

/** Per-LynxView JS console observer; this is what makes Console page-selectable. */
internal object LynxConsoleSink {
    private val attached = WeakHashMap<LynxView, LynxInspectorConsoleDelegate>()

    @Synchronized
    fun attach(view: LynxView, viewId: String): Boolean {
        if (attached.containsKey(view)) return true
        val delegate = object : LynxInspectorConsoleDelegate {
            override fun onConsoleMessage(msg: String?) {
                if (msg.isNullOrBlank()) return
                ConsoleLogStore.add(parse(msg, viewId))
            }
        }
        val owner = runCatching { view.baseInspectorOwner }.getOrNull() ?: return false
        return runCatching {
            owner.setLynxInspectorConsoleDelegate(delegate)
            attached[view] = delegate
            true
        }.getOrDefault(false)
    }

    @Synchronized
    fun detach(view: LynxView) {
        if (attached.remove(view) == null) return
        runCatching { view.baseInspectorOwner?.setLynxInspectorConsoleDelegate(null) }
    }

    private fun parse(raw: String, viewId: String): ConsoleLog {
        return runCatching {
            val obj = JSONObject(raw)
            val type = obj.optString("type", "log").lowercase()
            val data = obj.optJSONArray("data")
            val message = if (data == null) obj.optString("message", raw) else format(data)
            ConsoleLog(
                type = type,
                level = when (type) {
                    "error" -> android.util.Log.ERROR
                    "warn" -> android.util.Log.WARN
                    "info" -> android.util.Log.INFO
                    "debug" -> android.util.Log.DEBUG
                    else -> android.util.Log.VERBOSE
                },
                message = message,
                tag = "console",
                viewId = viewId,
            )
        }.getOrElse {
            ConsoleLog("log", android.util.Log.VERBOSE, raw, "console", viewId = viewId)
        }
    }

    private fun format(data: JSONArray): String = buildString {
        for (index in 0 until data.length()) {
            if (index > 0) append('\t')
            when (val item = data.opt(index)) {
                null, JSONObject.NULL -> append("null")
                is JSONObject, is JSONArray -> append(item.toString())
                else -> append(item)
            }
        }
    }
}
