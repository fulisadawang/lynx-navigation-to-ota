package com.example.lynxcapacitormodule

import android.app.Activity
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.camera.core.CameraSelector
import java.lang.ref.WeakReference
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import org.json.JSONArray
import org.json.JSONObject

/**
 * 自有 Lynx Module 的 Android 条码扫描能力。
 *
 * 这里只负责请求登记、启动自有 Activity 和一次性消费结果，不创建 Capacitor runtime/plugin。
 * pending store 只保存 requestId、requestCode 和 callback，不保存 Activity，避免单例静态引用
 * Activity 导致泄露。BarcodeScanActivity 通过 [complete] 回传结果；宿主也可以把 Activity Result
 * 转发给 [onActivityResult] 作为兼容接线方式。
 */
object NativeBarcodeCapabilities {
    const val EXTRA_REQUEST_ID = "com.example.lynxcapacitormodule.barcode.REQUEST_ID"
    const val EXTRA_HINT = "com.example.lynxcapacitormodule.barcode.HINT"
    const val EXTRA_LENS_FACING = "com.example.lynxcapacitormodule.barcode.LENS_FACING"
    const val EXTRA_SCAN_INSTRUCTIONS = "com.example.lynxcapacitormodule.barcode.SCAN_INSTRUCTIONS"
    const val EXTRA_IGNORED_OPTIONS = "com.example.lynxcapacitormodule.barcode.IGNORED_OPTIONS"
    const val EXTRA_RESULT_JSON = "com.example.lynxcapacitormodule.barcode.RESULT_JSON"

    private const val METHOD_SCAN_BARCODE = "scanBarcode"
    private const val REQUEST_CODE_START = 48_000
    private const val REQUEST_CODE_END = 48_999
    private const val DEFAULT_HINT = 17

    private val mainHandler = Handler(Looper.getMainLooper())
    private val nextRequestCode = AtomicInteger(REQUEST_CODE_START)
    private val pendingRequests = ConcurrentHashMap<String, PendingRequest>()
    private val requestIdsByCode = ConcurrentHashMap<Int, String>()

    /**
     * 只认 scanBarcode；其它 method 返回 false，交由 dispatcher 的其它能力处理。
     *
     * complete 收到的是未包装的业务结果：成功对象包含真实条码字段，失败对象包含 error。
     */
    fun dispatch(
        activity: Activity,
        methodName: String,
        options: JSONObject,
        complete: (JSONObject) -> Unit,
    ): Boolean {
        if (methodName != METHOD_SCAN_BARCODE) return false

        val run = Runnable {
            dispatchOnMain(activity, options, complete)
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            run.run()
        } else {
            runCatching { activity.runOnUiThread(run) }
                .onFailure { completeOnMain(complete, error("ACTIVITY_DESTROYED", "Activity 无法切换到主线程")) }
        }
        return true
    }

    /**
     * Activity 直接完成时调用。requestId 一旦被消费，重复回传只返回 false，不会重复执行 callback。
     */
    fun complete(requestId: String, result: JSONObject): Boolean {
        val pending = pendingRequests.remove(requestId) ?: return false
        requestIdsByCode.remove(pending.requestCode, requestId)
        completeOnMain(pending.complete, runCatching { JSONObject(result.toString()) }.getOrElse {
            error("NATIVE_ERROR", "扫码结果无法序列化")
        })
        return true
    }

    /** Activity 销毁时取消该 Activity 发起的所有扫码请求，避免旧 callback 残留。 */
    fun release(activity: Activity) {
        pendingRequests.entries.toList().forEach { (requestId, pending) ->
            if (pending.activityReference.get() !== activity) return@forEach
            if (!pendingRequests.remove(requestId, pending)) return@forEach
            requestIdsByCode.remove(pending.requestCode, requestId)
            completeOnMain(pending.complete, error("ACTIVITY_DESTROYED", "Activity 已销毁，扫码请求已取消"))
        }
    }

    /**
     * 供宿主 Activity 的 onActivityResult 转发使用。
     *
     * 当前自有 Activity 会优先调用 [complete]，因此这里通常只作为备用路径；两条路径共享同一个
     * pending store，仍然保证 callback 只消费一次。
     */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val requestId = requestIdsByCode[requestCode] ?: return false
        val pending = pendingRequests[requestId] ?: return false
        if (pending.requestCode != requestCode) return false

        val result = if (resultCode != Activity.RESULT_OK) {
            error("CANCELLED", "用户取消了条码扫描")
        } else {
            val encoded = data?.getStringExtra(EXTRA_RESULT_JSON)
            runCatching { encoded?.let(::JSONObject) }
                .getOrNull()
                ?: error("SCAN_FAILED", "扫码 Activity 没有返回有效结果")
        }
        return complete(requestId, result)
    }

    private fun dispatchOnMain(
        activity: Activity,
        options: JSONObject,
        complete: (JSONObject) -> Unit,
    ) {
        if (activity.isFinishing || activity.isDestroyed) {
            complete(error("ACTIVITY_DESTROYED", "Activity 已销毁，无法启动条码扫描"))
            return
        }

        val prepared = prepare(options)
        if (prepared.error != null) {
            complete(prepared.error)
            return
        }

        val requestId = options.optString("requestId").trim().ifBlank { UUID.randomUUID().toString() }
        val requestCode = nextRequestCode()
        val request = PendingRequest(WeakReference(activity), requestCode, complete)
        if (pendingRequests.putIfAbsent(requestId, request) != null) {
            complete(error("BUSY", "requestId 对应的条码扫描仍在进行中").put("requestId", requestId))
            return
        }
        requestIdsByCode[requestCode] = requestId

        val intent = Intent(activity, BarcodeScanActivity::class.java).apply {
            putExtra(EXTRA_REQUEST_ID, requestId)
            putExtra(EXTRA_HINT, prepared.hint)
            putExtra(EXTRA_LENS_FACING, prepared.lensFacing)
            putExtra(EXTRA_SCAN_INSTRUCTIONS, prepared.scanInstructions)
            putExtra(EXTRA_IGNORED_OPTIONS, prepared.ignoredOptions.toString())
        }

        runCatching {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, requestCode)
        }.onFailure { throwable ->
            if (pendingRequests.remove(requestId, request)) {
                requestIdsByCode.remove(requestCode, requestId)
                complete(
                    error(
                        "UNAVAILABLE",
                        throwable.message ?: "无法启动条码扫描 Activity",
                    ).put("requestId", requestId),
                )
            }
        }
    }

    private fun prepare(options: JSONObject): PreparedScan {
        val hint = parseHint(options.opt("hint"))
            ?: return PreparedScan.error("hint 必须是 0 到 17 的整数", "INVALID_ARGUMENT")
        val unsupportedHint = hint in UNSUPPORTED_ML_KIT_HINTS
        if (unsupportedHint) {
            return PreparedScan.error(
                "hint=$hint 对应的条码格式不在 ML Kit Barcode Scanning 支持范围内",
                "UNSUPPORTED_HINT",
            ).copy(hint = hint)
        }

        val lensFacing = parseCameraDirection(options.opt("cameraDirection"))
            ?: return PreparedScan.error(
                "cameraDirection 只支持 BACK/FRONT 或数值 1/2",
                "INVALID_ARGUMENT",
            ).copy(hint = hint)

        val androidOptions = options.optJSONObject("android")
        val scanningLibrary = androidOptions?.takeUnless { it === JSONObject.NULL }
            ?.optString("scanningLibrary")
            ?.trim()
            ?.lowercase()
        if (!scanningLibrary.isNullOrEmpty() && scanningLibrary != "mlkit") {
            return PreparedScan.error(
                "当前自有 Android 实现只使用 ML Kit，不支持 scanningLibrary=$scanningLibrary",
                "UNSUPPORTED_OPTION",
            ).copy(hint = hint, lensFacing = lensFacing)
        }

        val ignoredOptions = ignoredOptions(options, androidOptions)
        val instructions = options.optString("scanInstructions").trim().take(200)
        return PreparedScan(
            hint = hint,
            lensFacing = lensFacing,
            scanInstructions = instructions,
            ignoredOptions = ignoredOptions,
            error = null,
        )
    }

    private fun parseHint(raw: Any?): Int? {
        if (raw == null || raw === JSONObject.NULL) return DEFAULT_HINT
        val value = when (raw) {
            is Number -> raw.toDouble().takeIf { it.isFinite() && it % 1.0 == 0.0 }?.toInt()
            is String -> raw.trim().toIntOrNull()
            else -> null
        } ?: return null
        return value.takeIf { it in 0..17 }
    }

    private fun parseCameraDirection(raw: Any?): Int? {
        if (raw == null || raw === JSONObject.NULL) return CameraSelector.LENS_FACING_BACK
        return when (raw) {
            is Number -> when (raw.toInt()) {
                1 -> CameraSelector.LENS_FACING_BACK
                2 -> CameraSelector.LENS_FACING_FRONT
                else -> null
            }
            is String -> when (raw.trim().uppercase()) {
                "BACK", "1" -> CameraSelector.LENS_FACING_BACK
                "FRONT", "2" -> CameraSelector.LENS_FACING_FRONT
                else -> null
            }
            else -> null
        }
    }

    private fun ignoredOptions(options: JSONObject, androidOptions: JSONObject?): JSONArray {
        val ignored = JSONArray()
        val supported = setOf("requestId", "hint", "cameraDirection", "scanInstructions", "android")
        options.keys().forEach { key ->
            if (key !in supported) ignored.put(key)
        }
        androidOptions?.keys()?.forEach { key ->
            if (key != "scanningLibrary") ignored.put("android.$key")
        }
        return ignored
    }

    private fun completeOnMain(complete: (JSONObject) -> Unit, result: JSONObject) {
        val deliver = Runnable { runCatching { complete(result) } }
        if (Looper.myLooper() == Looper.getMainLooper()) deliver.run() else mainHandler.post(deliver)
    }

    private fun nextRequestCode(): Int = nextRequestCode.getAndUpdate { current ->
        if (current >= REQUEST_CODE_END) REQUEST_CODE_START else current + 1
    }

    private fun error(code: String, message: String): JSONObject = JSONObject()
        .put("error", JSONObject().put("code", code).put("message", message))

    private data class PendingRequest(
        val activityReference: WeakReference<Activity>,
        val requestCode: Int,
        val complete: (JSONObject) -> Unit,
    )

    private data class PreparedScan(
        val hint: Int,
        val lensFacing: Int = CameraSelector.LENS_FACING_BACK,
        val scanInstructions: String = "",
        val ignoredOptions: JSONArray = JSONArray(),
        val error: JSONObject? = null,
    ) {
        companion object {
            fun error(message: String, code: String): PreparedScan = PreparedScan(
                hint = DEFAULT_HINT,
                error = JSONObject()
                    .put("error", JSONObject().put("code", code).put("message", message)),
            )
        }
    }

    // ML Kit 不支持 MAXICODE、RSS-14、RSS_EXPANDED、UPC_EAN_EXTENSION。
    private val UNSUPPORTED_ML_KIT_HINTS = setOf(7, 12, 13, 16)
}
