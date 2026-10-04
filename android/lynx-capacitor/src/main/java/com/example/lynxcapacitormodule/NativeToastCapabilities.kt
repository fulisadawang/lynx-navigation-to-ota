package com.example.lynxcapacitormodule

import android.app.Activity
import android.os.Build
import android.view.Gravity
import android.widget.Toast
import java.util.Locale
import java.util.WeakHashMap
import org.json.JSONArray
import org.json.JSONObject

/** Android Toast 的自有实现，保留 Capacitor 参数并报告系统位置限制。 */
object NativeToastCapabilities {
    private const val PLUGIN_ID = "Toast"
    private const val TOP_OFFSET_DP = 64

    private val activeToasts = WeakHashMap<Activity, Toast>()
    private val toastOwners = WeakHashMap<Activity, NativeOwnerScope>()

    /** Activity 销毁时取消仍由当前 Module 持有的 Toast，避免短生命周期页面残留。 */
    fun release(activity: Activity) {
        val toast = synchronized(activeToasts) { activeToasts.remove(activity) }
        toast?.cancel()
    }

    /** 返回 null 表示交给其它能力域；Toast 方法始终返回真实显示/位置边界。 */
    fun dispatch(
        activity: Activity,
        pluginId: String,
        methodName: String,
        options: JSONObject,
    ): JSONObject? {
        if (pluginId != PLUGIN_ID) return null
        if (android.os.Looper.myLooper() != android.os.Looper.getMainLooper()) {
            return error("UI_THREAD_REQUIRED", "Toast Android API 必须在主线程调用")
        }
        return runCatching {
            when (methodName) {
                "show" -> show(activity, options)
                "getCapabilities" -> getCapabilities()
                "cancel" -> cancel(activity)
                else -> error("UNSUPPORTED", "Toast.$methodName 尚未接入当前 Android Module")
            }
        }.getOrElse { throwable ->
            error("NATIVE_ERROR", throwable.message ?: "Android Toast 调用失败")
        }
    }

    private fun show(activity: Activity, options: JSONObject): JSONObject {
        val rawText = options.opt("text")
        if (rawText == null || rawText === JSONObject.NULL) {
            return error("INVALID_ARGUMENT", "text 不能为空")
        }
        if (rawText !is String) {
            return error("INVALID_ARGUMENT", "text 必须是字符串")
        }
        val durationName = options.optString("duration", "short").trim().lowercase(Locale.US)
        val duration = when (durationName) {
            "short" -> Toast.LENGTH_SHORT
            "long" -> Toast.LENGTH_LONG
            else -> return error("INVALID_ARGUMENT", "duration 只支持 short 或 long")
        }
        val position = options.optString("position", "bottom").trim().lowercase(Locale.US)
        if (position !in POSITIONS) {
            return error("INVALID_ARGUMENT", "position 只支持 top、center 或 bottom")
        }

        val owner = NativeCallContext.owner
        if (activeToasts[activity] != null && toastOwners[activity] !== owner) return error("BUSY", "其他页面仍在显示 Toast")
        val previous = synchronized(activeToasts) { activeToasts.remove(activity) }
        previous?.let { owner?.disown(it) }
        previous?.cancel()
        val toast = Toast.makeText(activity, rawText, duration)
        val positionApplied = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || position == "bottom"
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            val gravity = when (position) {
                "top" -> Gravity.TOP
                "center" -> Gravity.CENTER
                else -> Gravity.BOTTOM
            }
            val yOffset = if (position == "top") {
                (TOP_OFFSET_DP * activity.resources.displayMetrics.density).toInt()
            } else {
                0
            }
            toast.setGravity(gravity, 0, yOffset)
        }
        toast.show()
        synchronized(activeToasts) { activeToasts[activity] = toast; if (owner != null) toastOwners[activity] = owner }
        owner?.own(toast) {
            activity.runOnUiThread {
                synchronized(activeToasts) { if (activeToasts[activity] === toast) { activeToasts.remove(activity); toastOwners.remove(activity) } }
                toast.cancel()
            }
        }
        // API 26-29 无 Toast.Callback；系统标准显示窗口结束后归还持有，避免持有直到页面退出。
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            owner?.disown(toast)
            synchronized(activeToasts) { if (activeToasts[activity] === toast) { activeToasts.remove(activity); toastOwners.remove(activity) } }
        }, if (duration == Toast.LENGTH_LONG) 3500L else 2000L)
        return JSONObject()
            .put("shown", true)
            .put("text", rawText)
            .put("duration", durationName)
            .put("durationConstant", if (duration == Toast.LENGTH_LONG) "LENGTH_LONG" else "LENGTH_SHORT")
            .put("requestedPosition", position)
            .put("effectivePosition", if (positionApplied) position else "bottom")
            .put("positionApplied", positionApplied)
            .put("android12PositionRule", "Android 12+ text Toast 固定显示在底部")
    }

    private fun getCapabilities(): JSONObject = JSONObject()
        .put("supported", true)
        .put("apiLevel", Build.VERSION.SDK_INT)
        .put("durations", JSONArray().put("short").put("long"))
        .put("positions", if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            JSONArray().put("top").put("center").put("bottom")
        } else {
            JSONArray().put("bottom")
        })
        .put("supportsCustomPosition", Build.VERSION.SDK_INT < Build.VERSION_CODES.S)
        .put("supportsCancel", true)

    private fun cancel(activity: Activity): JSONObject {
        if (activeToasts[activity] != null && toastOwners[activity] !== NativeCallContext.owner) return error("FORBIDDEN", "不能取消其他页面的 Toast")
        val toast = synchronized(activeToasts) { activeToasts.remove(activity) }
        toast?.cancel()
        toast?.let { NativeCallContext.owner?.disown(it) }
        toastOwners.remove(activity)
        return JSONObject().put("cancelled", toast != null)
    }

    private fun error(code: String, message: String): JSONObject = JSONObject()
        .put("error", JSONObject().put("code", code).put("message", message))

    private val POSITIONS = setOf("top", "center", "bottom")
}
