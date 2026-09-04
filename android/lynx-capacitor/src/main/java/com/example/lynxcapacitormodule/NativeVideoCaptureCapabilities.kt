package com.example.lynxcapacitormodule

import android.app.Activity
import android.content.Intent
import android.os.Handler
import android.os.Looper
import java.lang.ref.WeakReference
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import org.json.JSONObject

/** Camera.recordVideo 的自有请求登记器；录像本身由 VideoCaptureActivity 负责。 */
object NativeVideoCaptureCapabilities {
    const val EXTRA_REQUEST_ID = "com.example.lynxcapacitormodule.video.REQUEST_ID"
    const val EXTRA_RESULT_JSON = "com.example.lynxcapacitormodule.video.RESULT_JSON"
    const val EXTRA_SAVE_TO_GALLERY = "com.example.lynxcapacitormodule.video.SAVE_TO_GALLERY"
    const val EXTRA_IS_PERSISTENT = "com.example.lynxcapacitormodule.video.IS_PERSISTENT"
    const val EXTRA_INCLUDE_METADATA = "com.example.lynxcapacitormodule.video.INCLUDE_METADATA"

    private const val REQUEST_CODE_START = 49_000
    private const val REQUEST_CODE_END = 49_999
    private val mainHandler = Handler(Looper.getMainLooper())
    private val nextRequestCode = AtomicInteger(REQUEST_CODE_START)
    private val lock = Any()
    private var pendingRequest: PendingRequest? = null

    fun dispatch(
        activity: Activity,
        methodName: String,
        options: JSONObject,
        complete: (JSONObject) -> Unit,
    ): Boolean {
        if (methodName == "playVideo") {
            val rawUri = options.optString("uri").trim()
            val uri = runCatching { android.net.Uri.parse(rawUri) }.getOrNull()
            if (rawUri.isEmpty() || uri?.scheme.isNullOrEmpty()) {
                complete(error("INVALID_ARGUMENT", "playVideo 需要合法 uri"))
                return true
            }
            runCatching {
                activity.startActivity(
                    Intent(activity, VideoPlaybackActivity::class.java)
                        .putExtra(VideoPlaybackActivity.EXTRA_URI, rawUri),
                )
            }.onSuccess {
                complete(JSONObject().put("playing", true).put("uri", rawUri))
            }.onFailure { throwable ->
                complete(error("UNAVAILABLE", throwable.message ?: "无法启动视频播放器"))
            }
            return true
        }
        if (methodName != "recordVideo") return false

        val permissionStatus = NativePermissionCoordinator.check(activity, "Camera", options)
        if (permissionStatus?.has("error") == true) {
            complete(permissionStatus)
            return true
        }
        if (permissionStatus?.optString("camera") != "granted") {
            complete(error("PERMISSION_DENIED", "录像前请先点击 Camera.requestPermissions 授予相机权限"))
            return true
        }

        val requestId = options.optString("requestId").trim().ifBlank { UUID.randomUUID().toString() }
        val requestCode = nextRequestCode()
        val request = PendingRequest(WeakReference(activity), requestId, requestCode, complete)
        synchronized(lock) {
            if (pendingRequest != null) {
                complete(error("BUSY", "已有一个录像请求正在进行"))
                return true
            }
            pendingRequest = request
        }

        val intent = Intent(activity, VideoCaptureActivity::class.java).apply {
            putExtra(EXTRA_REQUEST_ID, requestId)
            putExtra(EXTRA_SAVE_TO_GALLERY, options.optBoolean("saveToGallery", false))
            putExtra(EXTRA_IS_PERSISTENT, options.optBoolean("isPersistent", true))
            putExtra(EXTRA_INCLUDE_METADATA, options.optBoolean("includeMetadata", false))
        }
        runCatching {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, requestCode)
        }.onFailure { throwable ->
            val consumed = synchronized(lock) {
                if (pendingRequest === request) {
                    pendingRequest = null
                    true
                } else {
                    false
                }
            }
            if (consumed) complete(error("UNAVAILABLE", throwable.message ?: "无法启动录像 Activity"))
        }
        return true
    }

    /** VideoCaptureActivity 直接回传时消费请求；重复回传不会二次调用 callback。 */
    fun complete(requestId: String, result: JSONObject): Boolean {
        val request = synchronized(lock) {
            val current = pendingRequest ?: return@synchronized null
            if (current.requestId != requestId) return@synchronized null
            pendingRequest = null
            current
        } ?: return false
        completeOnMain(request.complete, result)
        return true
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val request = synchronized(lock) {
            val current = pendingRequest ?: return@synchronized null
            if (current.requestCode != requestCode) return@synchronized null
            pendingRequest = null
            current
        } ?: return false
        val result = if (resultCode == Activity.RESULT_OK) {
            data?.getStringExtra(EXTRA_RESULT_JSON)?.let { raw ->
                runCatching { JSONObject(raw) }.getOrNull()
            } ?: error("NATIVE_ERROR", "录像 Activity 没有返回有效结果")
        } else {
            error("CANCELLED", "用户取消了录像")
        }
        completeOnMain(request.complete, result)
        return true
    }

    fun release(activity: Activity) {
        val request = synchronized(lock) {
            val current = pendingRequest
            if (current == null || current.activityReference.get() !== activity) null
            else {
                pendingRequest = null
                current
            }
        } ?: return
        completeOnMain(request.complete, error("ACTIVITY_DESTROYED", "Activity 已销毁，录像请求已取消"))
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
        val requestId: String,
        val requestCode: Int,
        val complete: (JSONObject) -> Unit,
    )
}
