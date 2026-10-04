package com.example.lynxcapacitormodule

import android.app.Activity
import android.app.AlertDialog
import android.os.Handler
import android.os.Looper
import java.lang.ref.WeakReference
import java.util.Locale
import org.json.JSONArray
import org.json.JSONObject

/** 来源菜单与权限归属于调用 Lynx 页面；业务也可直接指定来源，不依赖 Lynx Bottom Sheet。 */
internal object NativeMediaSourceCapabilities {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val lock = Any()
    private var pending: Selection? = null
    val isBusy: Boolean get() = synchronized(lock) { pending != null }

    fun select(activity: Activity, method: String, options: JSONObject, complete: (JSONObject) -> Unit) {
        val source: String
        val mediaType: Int
        try {
            source = options.optString("source", if (method == "getPhoto") "PROMPT" else "PHOTOS").uppercase(Locale.US)
            require(source in setOf("PHOTOS", "CAMERA", "PROMPT")) { "source 必须为 PHOTOS、CAMERA 或 PROMPT" }
            mediaType = if (method == "getPhoto") 0 else readMediaType(options)
            NativeCameraCaptureCapabilities.readSelectionCount(options, "limit", 0)
            for (key in listOf("saveToGallery", "includeMicrophone", "includeMetadata", "allowMultipleSelection")) {
                require(!options.has(key) || options.opt(key) is Boolean) { "$key 必须为布尔值" }
            }
            if (options.has("cameraDirection")) require(options.optString("cameraDirection").uppercase(Locale.US) in setOf("FRONT", "BACK")) {
                "cameraDirection 必须为 FRONT 或 BACK"
            }
            for (key in listOf("promptLabelHeader", "promptLabelPhotos", "promptLabelTakePhoto", "promptLabelRecordVideo", "promptLabelCancel")) {
                require(!options.has(key) || options.opt(key) is String) { "$key 必须为字符串" }
            }
        } catch (failure: IllegalArgumentException) {
            complete(error("INVALID_ARGUMENT", failure.message ?: "媒体来源参数无效")); return
        }
        val selection = Selection(WeakReference(activity), NativeCallContext.owner, method, JSONObject(options.toString()), mediaType, complete)
        val accepted = synchronized(lock) {
            if (pending != null || NativeCameraCaptureCapabilities.hasPendingRequest() || NativeVideoCaptureCapabilities.hasPendingRequest()) false
            else { pending = selection; true }
        }
        if (!accepted) { complete(error("BUSY", "已有一个媒体来源或拍摄请求正在进行")); return }
        selection.owner?.own(selection) {
            synchronized(lock) { if (pending === selection) pending = null; selection.complete = null }
            mainHandler.post { selection.dialog?.dismiss(); selection.dialog = null }
        }
        onMain {
            if (!isActive(selection)) return@onMain
            NativeCallContext.withOwner(selection.owner) {
                when {
                    source == "PHOTOS" -> useSource(selection, Choice.PHOTOS)
                    source == "CAMERA" && mediaType != 2 -> useSource(selection, if (mediaType == 0) Choice.PHOTO else Choice.VIDEO)
                    else -> showMenu(selection, source == "PROMPT")
                }
            }
        }
    }

    private fun showMenu(selection: Selection, withPhotos: Boolean) {
        val activity = usableActivity(selection) ?: return
        val choices = buildList {
            if (withPhotos) add(Choice.PHOTOS)
            if (selection.mediaType != 1) add(Choice.PHOTO)
            if (selection.mediaType != 0) add(Choice.VIDEO)
        }
        val labels = choices.map { choice -> when (choice) {
            Choice.PHOTOS -> label(selection, "promptLabelPhotos", "从相册选择")
            Choice.PHOTO -> label(selection, "promptLabelTakePhoto", "立即拍照")
            Choice.VIDEO -> label(selection, "promptLabelRecordVideo", "立即录像")
        } }.toTypedArray()
        try {
            selection.dialog = AlertDialog.Builder(activity)
                .setTitle(label(selection, "promptLabelHeader", "选择媒体来源"))
                .setItems(labels) { _, index ->
                    selection.dialog = null
                    if (isActive(selection)) NativeCallContext.withOwner(selection.owner) { useSource(selection, choices[index]) }
                }
                .setNegativeButton(label(selection, "promptLabelCancel", "取消")) { _, _ -> finish(selection, error("CANCELLED", "用户取消了媒体来源选择")) }
                .setOnCancelListener { finish(selection, error("CANCELLED", "用户取消了媒体来源选择")) }
                .create().also { it.show() }
        } catch (failure: Exception) { finish(selection, error("UNAVAILABLE", failure.message ?: "无法打开媒体来源菜单")) }
    }

    private fun useSource(selection: Selection, choice: Choice) {
        val activity = usableActivity(selection) ?: return
        if (choice == Choice.PHOTOS) {
            val gallery = JSONObject(selection.options.toString()).put("source", "PHOTOS")
            NativeCameraCaptureCapabilities.dispatchResolved(activity, selection.method, gallery) { finish(selection, it) }
            return
        }
        // 只在用户决定拍摄后申请相机；有声录像才额外申请麦克风。
        val permission = JSONObject().put("permissions", JSONArray().put("camera"))
            .put("includeMicrophone", choice == Choice.VIDEO && selection.options.opt("includeMicrophone") == true)
            .put("saveToGallery", selection.options.optBoolean("saveToGallery", selection.method == "getPhoto"))
        NativePermissionCoordinator.request(activity, "Camera", "requestPermissions", permission) { status ->
            onMain {
                if (!isActive(selection)) return@onMain
                NativeCallContext.withOwner(selection.owner) {
                    if (status.has("error")) finish(selection, status)
                    else if (status.optString("camera") != "granted" ||
                        (permission.optBoolean("includeMicrophone") && status.optString("microphone") != "granted") ||
                        (permission.optBoolean("saveToGallery") && status.optString("photosAdd") != "granted")) {
                        finish(selection, error("PERMISSION_DENIED", "拍摄所需权限未授予"))
                    } else {
                        val capture = JSONObject(selection.options.toString()).put("source", "CAMERA")
                        val callback: (JSONObject) -> Unit = { result ->
                            if (selection.method != "chooseFromGallery" || result.has("error")) finish(selection, result)
                            else {
                                val uri = result.optString("uri")
                                if (uri.isBlank()) finish(selection, error("NO_MEDIA_URI", "拍摄没有返回媒体 URI"))
                                else finish(selection, JSONObject().put("results", JSONArray().put(result
                                    .put("type", if (choice == Choice.PHOTO) 0 else 1)
                                    .put("mimeType", result.optString("mimeType", if (choice == Choice.PHOTO) "image/jpeg" else "video/mp4"))))
                                    .put("uris", JSONArray().put(uri)))
                            }
                        }
                        val currentActivity = usableActivity(selection) ?: return@withOwner
                        if (choice == Choice.VIDEO) NativeVideoCaptureCapabilities.dispatchResolved(currentActivity, "recordVideo", capture, callback)
                        else NativeCameraCaptureCapabilities.dispatchResolved(currentActivity,
                            if (selection.method == "getPhoto") "getPhoto" else "takePhoto", capture, callback)
                    }
                }
            }
        }
    }

    private fun usableActivity(selection: Selection): Activity? {
        val activity = selection.activity.get()
        if (activity == null || activity.isDestroyed || activity.isFinishing) {
            finish(selection, error("HOST_DESTROYED", "媒体宿主已销毁")); return null
        }
        return activity
    }
    private fun isActive(selection: Selection): Boolean = selection.owner?.isActive != false && synchronized(lock) { pending === selection }
    private fun finish(selection: Selection, result: JSONObject) {
        val callback = synchronized(lock) {
            if (pending !== selection) return
            pending = null
            selection.complete.also { selection.complete = null }
        }
        selection.owner?.disown(selection)
        onMain { selection.dialog?.dismiss(); selection.dialog = null; callback?.invoke(result) }
    }
    private fun readMediaType(options: JSONObject): Int {
        if (!options.has("mediaType")) return 0
        val raw = options.opt("mediaType")
        val value = when (raw) {
            is Number -> raw.toDouble().takeIf { it.isFinite() && it % 1 == 0.0 }?.toInt()
            is String -> raw.toIntOrNull()
            else -> null
        }
        require(value != null && value in 0..2) { "mediaType 必须为 0（图片）、1（视频）或 2（混合）" }
        return requireNotNull(value)
    }
    private fun label(selection: Selection, key: String, fallback: String): String = selection.options.optString(key).ifBlank { fallback }
    private fun onMain(action: () -> Unit) { if (Looper.myLooper() == Looper.getMainLooper()) action() else mainHandler.post(action) }
    private fun error(code: String, message: String): JSONObject = JSONObject().put("error", JSONObject().put("code", code).put("message", message))
    private enum class Choice { PHOTOS, PHOTO, VIDEO }
    private class Selection(val activity: WeakReference<Activity>, val owner: NativeOwnerScope?, val method: String,
        val options: JSONObject, val mediaType: Int, var complete: ((JSONObject) -> Unit)?) {
        var dialog: AlertDialog? = null
    }
}
