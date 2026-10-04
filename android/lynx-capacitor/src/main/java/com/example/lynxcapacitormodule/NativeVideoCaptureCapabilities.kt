package com.example.lynxcapacitormodule

import android.app.Activity
import android.content.Intent
import android.os.Handler
import android.os.Looper
import java.lang.ref.WeakReference
import java.util.UUID
import java.util.Locale
import java.util.concurrent.atomic.AtomicInteger
import org.json.JSONObject

/** Camera.recordVideo 的自有请求登记器；录像本身由 VideoCaptureActivity 负责。 */
object NativeVideoCaptureCapabilities {
    const val EXTRA_REQUEST_ID = "com.example.lynxcapacitormodule.video.REQUEST_ID"
    const val EXTRA_RESULT_JSON = "com.example.lynxcapacitormodule.video.RESULT_JSON"
    const val EXTRA_SAVE_TO_GALLERY = "com.example.lynxcapacitormodule.video.SAVE_TO_GALLERY"
    const val EXTRA_IS_PERSISTENT = "com.example.lynxcapacitormodule.video.IS_PERSISTENT"
    const val EXTRA_INCLUDE_METADATA = "com.example.lynxcapacitormodule.video.INCLUDE_METADATA"
    const val EXTRA_LENS_FACING = "com.example.lynxcapacitormodule.video.LENS_FACING"
    const val EXTRA_INCLUDE_MICROPHONE = "com.example.lynxcapacitormodule.video.INCLUDE_MICROPHONE"

    private const val REQUEST_CODE_START = 49_000
    private const val REQUEST_CODE_END = 49_999
    private val mainHandler = Handler(Looper.getMainLooper())
    private val nextRequestCode = AtomicInteger(REQUEST_CODE_START)
    private val lock = Any()
    private var pendingRequest: PendingRequest? = null
    private val playbacks = LinkedHashMap<String, PlaybackRequest>()

    internal fun ownerForRequest(requestId: String): NativeOwnerScope? = synchronized(lock) {
        pendingRequest?.takeIf { it.requestId == requestId }?.owner
    }

    internal fun hasPendingRequest(): Boolean = synchronized(lock) { pendingRequest != null }

    fun dispatch(activity: Activity, methodName: String, options: JSONObject, complete: (JSONObject) -> Unit): Boolean {
        if (methodName == "recordVideo" && NativeMediaSourceCapabilities.isBusy) {
            complete(error("BUSY", "已有一个媒体来源或拍摄请求正在进行"))
            return true
        }
        return dispatchResolved(activity, methodName, options, complete)
    }

    internal fun dispatchResolved(
        activity: Activity,
        methodName: String,
        options: JSONObject,
        complete: (JSONObject) -> Unit,
    ): Boolean {
        if (methodName == "playVideo") {
            val owner = NativeCallContext.owner
            NativeIO.local.submit(owner, { complete(error("BUSY", "视频读取队列已满")) }) {
                try {
                    val raw = options.optString("uri").ifBlank { options.optString("path") }
                    val media = NativeMediaUri.resolve(activity, raw, options.optString("directory", "CACHE"), measureSize = false)
                    require(media.mimeType.startsWith("video/")) { "playVideo 需要真实视频 MIME" }
                    mainHandler.post {
                        if (owner?.isActive == false) return@post
                        NativeCallContext.withOwner(owner) { launchPlayback(activity, media.uri.toString(), complete) }
                    }
                } catch (failure: Exception) {
                    complete(error(if (failure is NativeBudgetExceeded) failure.code else "INVALID_ARGUMENT", failure.message ?: "视频 URI 不可读取"))
                }
            }
            return true
        }
        if (methodName != "recordVideo") return false

        if (options.has("cameraDirection") && (options.opt("cameraDirection") !is String ||
                options.optString("cameraDirection").uppercase(Locale.US) !in setOf("FRONT", "BACK"))) {
            complete(error("INVALID_ARGUMENT", "cameraDirection 必须为 FRONT 或 BACK")); return true
        }

        val includeMicrophone = if (options.has("includeMicrophone")) {
            val value = options.opt("includeMicrophone")
            if (value !is Boolean) { complete(error("INVALID_ARGUMENT", "includeMicrophone 必须为布尔值")); return true }
            value
        } else null
        val permissionOptions = JSONObject().put("permissions", org.json.JSONArray().put("camera"))
            .put("includeMicrophone", includeMicrophone == true).put("saveToGallery", options.optBoolean("saveToGallery", false))
        val permissionStatus = NativePermissionCoordinator.check(activity, "Camera", permissionOptions)
        if (permissionStatus?.has("error") == true) {
            complete(permissionStatus)
            return true
        }
        if (permissionStatus?.optString("camera") != "granted") {
            complete(error("PERMISSION_DENIED", "录像前请先点击 Camera.requestPermissions 授予相机权限"))
            return true
        }

        if (includeMicrophone == true && permissionStatus?.optString("microphone") != "granted") {
            complete(error("PERMISSION_DENIED", "有声录像前请先授予麦克风权限"))
            return true
        }
        if (permissionOptions.optBoolean("saveToGallery") && permissionStatus?.optString("photosAdd") != "granted") {
            complete(error("PERMISSION_DENIED", "保存相册前请先授予写入权限")); return true
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

        request.owner?.own(request) {
            mainHandler.post {
                val consumed = synchronized(lock) {
                    if (pendingRequest === request) { pendingRequest = null; true } else false
                }
                if (consumed) activity.finishActivity(request.requestCode)
            }
        }
        val intent = Intent(activity, VideoCaptureActivity::class.java).apply {
            putExtra(EXTRA_REQUEST_ID, requestId)
            putExtra(EXTRA_SAVE_TO_GALLERY, options.optBoolean("saveToGallery", false))
            putExtra(EXTRA_IS_PERSISTENT, options.optBoolean("isPersistent", true))
            putExtra(EXTRA_INCLUDE_METADATA, options.optBoolean("includeMetadata", false))
            includeMicrophone?.let { putExtra(EXTRA_INCLUDE_MICROPHONE, it) }
            putExtra(EXTRA_LENS_FACING, if (options.optString("cameraDirection").equals("FRONT", ignoreCase = true))
                androidx.camera.core.CameraSelector.LENS_FACING_FRONT else androidx.camera.core.CameraSelector.LENS_FACING_BACK)
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
            if (consumed) { request.owner?.disown(request); complete(error("UNAVAILABLE", throwable.message ?: "无法启动录像 Activity")) }
        }
        return true
    }

    private fun launchPlayback(activity: Activity, uri: String, complete: (JSONObject) -> Unit) {
        if (activity.isFinishing || activity.isDestroyed) { complete(error("HOST_DESTROYED", "视频宿主已销毁")); return }
        val request = PlaybackRequest(UUID.randomUUID().toString(), WeakReference(activity), nextRequestCode(), NativeCallContext.owner, uri, complete)
        synchronized(lock) { playbacks[request.id] = request }
        request.owner?.own(request) {
            mainHandler.post {
                synchronized(lock) { playbacks.remove(request.id); request.complete = null }
                request.player.get()?.finish() ?: request.activity.get()?.finishActivity(request.requestCode)
            }
        }
        try {
            NativeCallContext.checkActive()
            @Suppress("DEPRECATION")
            activity.startActivityForResult(Intent(activity, VideoPlaybackActivity::class.java)
                .putExtra(VideoPlaybackActivity.EXTRA_URI, uri).putExtra(EXTRA_REQUEST_ID, request.id), request.requestCode)
        } catch (failure: Exception) {
            finishPlayback(request.id, error("UNAVAILABLE", failure.message ?: "无法启动视频播放器"))
        }
    }

    internal fun attachPlayback(id: String, activity: VideoPlaybackActivity): Boolean = synchronized(lock) {
        val request = playbacks[id] ?: return@synchronized false
        if (request.owner?.isActive == false) return@synchronized false
        request.player = WeakReference(activity)
        true
    }

    internal fun playbackReady(id: String) {
        val pair = synchronized(lock) {
            val request = playbacks[id] ?: return
            val callback = request.complete ?: return
            request.complete = null
            callback to request.uri
        }
        completeOnMain(pair.first, JSONObject().put("playing", true).put("uri", pair.second))
    }

    internal fun finishPlayback(id: String, result: JSONObject = error("CANCELLED", "视频预览已关闭")) {
        val request = synchronized(lock) { playbacks.remove(id) } ?: return
        request.owner?.disown(request)
        val callback = synchronized(lock) { request.complete.also { request.complete = null } }
        callback?.let { completeOnMain(it, result) }
    }

    /** VideoCaptureActivity 直接回传时消费请求；重复回传不会二次调用 callback。 */
    fun complete(requestId: String, result: JSONObject): Boolean {
        val request = synchronized(lock) {
            val current = pendingRequest ?: return@synchronized null
            if (current.requestId != requestId) return@synchronized null
            pendingRequest = null
            current
        } ?: return false
        request.owner?.disown(request)
        completeOnMain(request.complete, result)
        return true
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val playback = synchronized(lock) { playbacks.values.firstOrNull { it.requestCode == requestCode } }
        if (playback != null) { finishPlayback(playback.id); return true }
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
        request.owner?.disown(request)
        completeOnMain(request.complete, result)
        return true
    }

    fun release(activity: Activity) {
        val owned = synchronized(lock) { playbacks.values.filter { it.activity.get() === activity } }
        owned.forEach { it.player.get()?.finish(); finishPlayback(it.id) }
        val request = synchronized(lock) {
            val current = pendingRequest
            if (current == null || current.activityReference.get() !== activity) null
            else {
                pendingRequest = null
                current
            }
        } ?: return
        request.owner?.disown(request)
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

    private class PlaybackRequest(val id: String, val activity: WeakReference<Activity>, val requestCode: Int,
        val owner: NativeOwnerScope?, val uri: String, var complete: ((JSONObject) -> Unit)?) {
        var player: WeakReference<VideoPlaybackActivity> = WeakReference(null)
    }

    private data class PendingRequest(
        val activityReference: WeakReference<Activity>,
        val requestId: String,
        val requestCode: Int,
        val complete: (JSONObject) -> Unit,
        val owner: NativeOwnerScope? = NativeCallContext.owner,
    )
}
