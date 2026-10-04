package com.example.lynxcapacitormodule

import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.OpenableColumns
import java.lang.ref.WeakReference
import java.util.Locale
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

/**
 * Camera 的拍照和图片选择能力。
 *
 * 这是自有 Lynx Module 的能力实现，只使用 Android framework，不创建 Capacitor Bridge，
 * 拍照预览使用当前 Module 自己的 CameraX Activity，图片选择使用 Android Photo Picker。
 * 权限检查/申请由 NativePermissionCoordinator 负责。
 */
object NativeCameraCaptureCapabilities {
    const val EXTRA_REQUEST_ID = "com.example.lynxcapacitormodule.camera.REQUEST_ID"
    const val EXTRA_RESULT_JSON = "com.example.lynxcapacitormodule.camera.RESULT_JSON"
    private const val REQUEST_CODE_START = 47_000
    private const val REQUEST_CODE_END = 47_999
    private const val CAMERA_MIME_TYPE = "image/jpeg"
    private const val CAMERA_RELATIVE_PATH = "Pictures/LynxCamera"
    internal const val MAX_SELECTED_MEDIA = 16

    private val mainHandler = Handler(Looper.getMainLooper())
    private val requestCode = java.util.concurrent.atomic.AtomicInteger(REQUEST_CODE_START)
    private val lock = Any()
    private var pendingRequest: PendingRequest? = null

    /** 外部数量仅接受整型 JSON number；0 表示默认多选预算，不表示无限选择。 */
    internal fun readSelectionCount(options: JSONObject, key: String, default: Int, minimum: Int = 0): Int {
        if (!options.has(key)) return default
        val raw = options.opt(key)
        require(raw is Number) { "$key 必须是整数" }
        val value = raw.toDouble()
        require(value.isFinite() && value % 1.0 == 0.0 && value in minimum.toDouble()..MAX_SELECTED_MEDIA.toDouble()) {
            "$key 必须为 $minimum 到 $MAX_SELECTED_MEDIA 的整数"
        }
        return value.toInt()
    }

    internal fun ownerForRequest(requestId: String): NativeOwnerScope? = synchronized(lock) {
        pendingRequest?.takeIf { it.requestId == requestId }?.owner
    }

    /** 供自有 Camera Activity 完成当前 pending 请求；同一个 requestId 只允许消费一次。 */
    fun complete(requestId: String, result: JSONObject): Boolean {
        val request = synchronized(lock) {
            val current = pendingRequest ?: return@synchronized null
            if (current.requestId != requestId) return@synchronized null
            pendingRequest = null
            current
        } ?: return false
        NativeIO.local.submit(request.owner, { complete(request, error("BUSY", "图片结果执行队列已满")) }) {
            val normalized = runCatching { normalizeResult(request, result) }.getOrElse { throwable ->
                error(if (throwable is NativeBudgetExceeded) throwable.code else "NATIVE_ERROR", throwable.message ?: "图片结果无效")
            }
            complete(request, normalized)
        }
        return true
    }

    /** Activity 销毁时取消 pending 媒体请求，并清理尚未提交的 MediaStore 临时项。 */
    fun release(activity: Activity) {
        val request = synchronized(lock) {
            val current = pendingRequest
            if (current == null || current.activityReference.get() !== activity) {
                null
            } else {
                pendingRequest = null
                current
            }
        } ?: return
        cleanupCameraOutput(request)
        complete(request, error("ACTIVITY_DESTROYED", "Activity 已销毁，媒体请求已取消"))
    }

    /**
     * 认领旧版 getPhoto/pickImages 和 Android 已闭合的现代 chooseFromGallery 图片分支；其它
     * 现代视频/编辑方法仍交给 dispatcher 返回明确的能力边界错误。
     *
     * 返回 true 表示本能力已经认领该方法。异步完成结果通过 complete 回传，结果对象不包
     * success/data envelope。
     */
    fun dispatch(activity: Activity, methodName: String, options: JSONObject, complete: (JSONObject) -> Unit): Boolean {
        if (methodName == METHOD_CHOOSE_FROM_GALLERY || methodName == METHOD_GET_PHOTO) {
            val source = options.optString("source", if (methodName == METHOD_GET_PHOTO) SOURCE_PROMPT else SOURCE_PHOTOS).uppercase(Locale.US)
            if (source !in setOf(SOURCE_CAMERA, SOURCE_PHOTOS, SOURCE_PROMPT)) {
                complete(error("INVALID_ARGUMENT", "source 必须为 PHOTOS、CAMERA 或 PROMPT"))
                return true
            }
            if (methodName == METHOD_CHOOSE_FROM_GALLERY || source == SOURCE_PROMPT) {
                NativeMediaSourceCapabilities.select(activity, methodName, options, complete)
                return true
            }
        }
        if (NativeMediaSourceCapabilities.isBusy) {
            complete(error("BUSY", "已有一个媒体来源或拍摄请求正在进行"))
            return true
        }
        return dispatchResolved(activity, methodName, options, complete)
    }

    internal fun hasPendingRequest(): Boolean = synchronized(lock) { pendingRequest != null }

    internal fun dispatchResolved(
        activity: Activity,
        methodName: String,
        options: JSONObject,
        complete: (JSONObject) -> Unit,
    ): Boolean {
        if (methodName !in setOf(METHOD_GET_PHOTO, METHOD_PICK_IMAGES, METHOD_CHOOSE_FROM_GALLERY, METHOD_TAKE_PHOTO)) return false

        if (options.has("cameraDirection") && (options.opt("cameraDirection") !is String ||
                options.optString("cameraDirection").uppercase(Locale.US) !in setOf("FRONT", "BACK"))) {
            complete(error("INVALID_ARGUMENT", "cameraDirection 必须为 FRONT 或 BACK")); return true
        }

        val source = options.optString("source", SOURCE_PROMPT).uppercase(Locale.US)
        val needsCamera = methodName == METHOD_TAKE_PHOTO ||
            (methodName == METHOD_GET_PHOTO && source != SOURCE_PHOTOS)
        // 系统选择器按返回 URI 授权；不把全库照片/视频权限当作相册 UI 的前置条件。
        if (needsCamera) {
            val permissionOptions = JSONObject().put("permissions", JSONArray().put("camera"))
                .put("saveToGallery", options.optBoolean("saveToGallery", methodName == METHOD_GET_PHOTO))
            val permissionStatus = NativePermissionCoordinator.check(activity, "Camera", permissionOptions)
            if (permissionStatus?.has("error") == true) {
                complete(permissionStatus)
                return true
            }
            if (permissionStatus?.optString("camera") != "granted") {
                complete(error("PERMISSION_DENIED", "拍照前请先授予相机权限"))
                return true
            }
            if (permissionOptions.optBoolean("saveToGallery") && permissionStatus?.optString("photosAdd") != "granted") {
                complete(error("PERMISSION_DENIED", "保存相册前请先授予写入权限")); return true
            }
        }

        val owner = NativeCallContext.owner
        val run = Runnable {
            if (owner?.isActive == false) return@Runnable
            NativeCallContext.withOwner(owner) { dispatchOnMain(activity, methodName, options, complete) }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            run.run()
        } else {
            runCatching { activity.runOnUiThread(run) }
                .onFailure { complete(error("ACTIVITY_DESTROYED", "Activity 无法切换到主线程")) }
        }
        return true
    }

    /**
     * 由宿主 Activity 的 onActivityResult 转发。
     *
     * 结果一旦被本对象认领，pending callback 会立即移除；即使系统重复转发同一个结果，
     * 也不会再次执行 callback。
     */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val request = synchronized(lock) {
            val current = pendingRequest ?: return@synchronized null
            if (current.requestCode != requestCode) return@synchronized null
            pendingRequest = null
            current
        } ?: return false

        val activity = request.activityReference.get()
        if (activity == null || activity.isFinishing || activity.isDestroyed) {
            complete(request, error("ACTIVITY_DESTROYED", "Activity 已销毁，无法完成媒体请求"))
            return true
        }

        // URI 读取和图片尺寸解析可能触发 provider I/O，不占用 Activity 主线程。
        NativeIO.local.submit(request.owner, { complete(request, error("BUSY", "图片结果执行队列已满")) }) {
            val result = runCatching {
                processActivityResult(request, resultCode, data)
            }.getOrElse { throwable ->
                cleanupCameraOutput(request)
                error(
                    if (throwable is CameraCaptureException) throwable.code else if (throwable is NativeBudgetExceeded) throwable.code else "NATIVE_ERROR",
                    throwable.message ?: "Android 媒体结果处理失败",
                )
            }
            complete(request, result)
        }
        return true
    }

    private fun dispatchOnMain(
        activity: Activity,
        methodName: String,
        options: JSONObject,
        complete: (JSONObject) -> Unit,
    ) {
        if (activity.isFinishing || activity.isDestroyed) {
            complete(error("ACTIVITY_DESTROYED", "Activity 已销毁，无法启动媒体请求"))
            return
        }

        // 没有 onActivityDestroyed 接口时，下一次调用负责回收已经失效的 pending 请求，
        // 避免旧 Activity 销毁后永久占用单例 callback 槽位。
        val staleRequest = synchronized(lock) {
            val stale = pendingRequest?.takeIf { pending ->
                val pendingActivity = pending.activityReference.get()
                pendingActivity == null || pendingActivity.isDestroyed || pendingActivity.isFinishing
            }
            if (stale != null) pendingRequest = null
            stale
        }
        if (staleRequest != null) {
            cleanupCameraOutput(staleRequest)
            complete(staleRequest, error("ACTIVITY_DESTROYED", "上一个媒体请求所属 Activity 已销毁"))
        }

        val alreadyPending = synchronized(lock) { pendingRequest != null }
        if (alreadyPending) {
            complete(error("BUSY", "已有一个媒体请求正在等待系统 Activity 结果"))
            return
        }

        val request = when (methodName) {
            METHOD_GET_PHOTO -> createGetPhotoRequest(activity, options, complete)
            METHOD_PICK_IMAGES -> createPickImagesRequest(activity, options, complete)
            METHOD_CHOOSE_FROM_GALLERY -> createChooseFromGalleryRequest(activity, options, complete)
            METHOD_TAKE_PHOTO -> createTakePhotoRequest(activity, options, complete)
            else -> null
        } ?: return

        val accepted = synchronized(lock) {
            if (pendingRequest == null) {
                pendingRequest = request
                true
            } else {
                false
            }
        }
        if (!accepted) {
            cleanupCameraOutput(request)
            complete(error("BUSY", "已有一个媒体请求正在等待系统 Activity 结果"))
            return
        }

        request.owner?.own(request) {
            mainHandler.post {
                val consumed = synchronized(lock) {
                    if (pendingRequest === request) { pendingRequest = null; true } else false
                }
                if (consumed) { cleanupCameraOutput(request); activity.finishActivity(request.requestCode) }
            }
        }
        runCatching {
            NativeCallContext.checkActive()
            @Suppress("DEPRECATION")
            activity.startActivityForResult(request.intent, request.requestCode)
        }.onFailure { throwable ->
            val consumed = synchronized(lock) {
                if (pendingRequest === request) {
                    pendingRequest = null
                    true
                } else {
                    false
                }
            }
            if (consumed) {
                request.owner?.disown(request)
                cleanupCameraOutput(request)
                complete(
                    error(
                        "UNAVAILABLE",
                        throwable.message ?: "无法打开 Android 媒体选择器",
                    ),
                )
            }
        }
    }

    private fun createGetPhotoRequest(
        activity: Activity,
        options: JSONObject,
        complete: (JSONObject) -> Unit,
        modern: Boolean = false,
    ): PendingRequest? {
        val source = options.optString("source", SOURCE_PROMPT).uppercase(Locale.US)
        val outputUri = when (source) {
            SOURCE_PROMPT -> createCameraOutputUri(activity)
            SOURCE_PHOTOS -> null
            else -> null
        }

        if (source == SOURCE_PROMPT) {
            if (outputUri == null) {
                complete(error("IO", "无法在 MediaStore 中创建相机输出 URI"))
                return null
            }
        }

        val requestId = UUID.randomUUID().toString()
        val nativeCameraIntent = Intent(activity, PhotoCaptureActivity::class.java).apply {
            putExtra(EXTRA_REQUEST_ID, requestId)
            putExtra(PhotoCaptureActivity.EXTRA_RESULT_TYPE, if (modern) "URI" else options.optString("resultType", "URI"))
            putExtra(
                PhotoCaptureActivity.EXTRA_SAVE_TO_GALLERY,
                options.optBoolean("saveToGallery", !modern),
            )
            putExtra(
                PhotoCaptureActivity.EXTRA_LENS_FACING,
                if (options.optString("cameraDirection").equals("FRONT", ignoreCase = true)) {
                    androidx.camera.core.CameraSelector.LENS_FACING_FRONT
                } else {
                    androidx.camera.core.CameraSelector.LENS_FACING_BACK
                },
            )
        }
        val cameraIntent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
            outputUri?.let { uri ->
                putExtra(MediaStore.EXTRA_OUTPUT, uri)
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        }
        val photoIntent = makePhotoPickerIntent(allowMultiple = false)
        val intent = when (source) {
            SOURCE_CAMERA -> {
                nativeCameraIntent
            }

            SOURCE_PHOTOS -> {
                if (!hasActivityHandler(activity, photoIntent)) {
                    cleanupUri(activity, outputUri)
                    complete(error("UNAVAILABLE", "设备没有可处理图片选择请求的 Activity"))
                    return null
                }
                photoIntent
            }

            else -> {
                // 未知 source 按上游兼容语义视为 PROMPT，由系统 chooser 提供相机/图片选择。
                if (!hasActivityHandler(activity, cameraIntent) ||
                    !hasActivityHandler(activity, photoIntent)
                ) {
                    cleanupUri(activity, outputUri)
                    complete(error("UNAVAILABLE", "设备没有可用的相机或图片选择 Activity"))
                    return null
                }
                Intent.createChooser(photoIntent, options.optString("promptLabelHeader").takeIf { it.isNotBlank() })
                    .apply {
                        putExtra(Intent.EXTRA_INITIAL_INTENTS, arrayOf(cameraIntent))
                    }
            }
        }

        return PendingRequest(
            requestId = requestId,
            activityReference = WeakReference(activity),
            requestCode = nextRequestCode(),
            kind = when (source) {
                SOURCE_CAMERA -> if (modern) RequestKind.TAKE_PHOTO else RequestKind.GET_PHOTO_CAMERA_NATIVE
                else -> RequestKind.GET_PHOTO
            },
            intent = intent,
            outputUri = outputUri,
            maxCount = 1,
            complete = complete,
            includeMetadata = modern && options.optBoolean("includeMetadata", false),
        )
    }

    private fun createTakePhotoRequest(
        activity: Activity,
        options: JSONObject,
        complete: (JSONObject) -> Unit,
    ): PendingRequest? {
        val takeOptions = JSONObject(options.toString()).put("source", SOURCE_CAMERA)
        return createGetPhotoRequest(activity, takeOptions, complete, modern = true)
    }

    private fun createPickImagesRequest(
        activity: Activity,
        options: JSONObject,
        complete: (JSONObject) -> Unit,
    ): PendingRequest? {
        // 保留旧版默认多选和显式 limit=1 的单选规则；0 使用统一 16 项预算。
        val limit = try { readSelectionCount(options, "limit", 0) }
        catch (failure: IllegalArgumentException) { complete(error("INVALID_ARGUMENT", failure.message ?: "选择数量无效")); return null }
        val allowMultiple = options.optBoolean("allowMultiple", false) || limit != 1
        val pickerIntent = try { makePhotoPickerIntent(allowMultiple, limit) }
        catch (throwable: IllegalArgumentException) { complete(error("INVALID_ARGUMENT", throwable.message ?: "选择数量无效")); return null }
        if (!hasActivityHandler(activity, pickerIntent)) {
            complete(error("UNAVAILABLE", "设备没有可处理图片选择请求的 Activity"))
            return null
        }

        return PendingRequest(
            requestId = UUID.randomUUID().toString(),
            activityReference = WeakReference(activity),
            requestCode = nextRequestCode(),
            kind = RequestKind.PICK_IMAGES,
            intent = pickerIntent,
            outputUri = null,
            maxCount = if (limit > 0) limit else MAX_SELECTED_MEDIA,
            complete = complete,
        )
    }

    private fun createChooseFromGalleryRequest(
        activity: Activity,
        options: JSONObject,
        complete: (JSONObject) -> Unit,
    ): PendingRequest? {
        val mediaType = options.opt("mediaType")
        val normalizedMediaType = when (mediaType) {
            null, JSONObject.NULL -> 0
            is Number -> mediaType.toDouble().takeIf { it.isFinite() && it % 1.0 == 0.0 }?.toInt()
            is String -> mediaType.trim().toIntOrNull()
            else -> null
        }
        if (normalizedMediaType !in setOf(0, 1, 2)) {
            complete(error("INVALID_ARGUMENT", "mediaType 必须为 0（图片）、1（视频）或 2（混合）"))
            return null
        }

        val requestedLimit = try { readSelectionCount(options, "limit", 0) }
        catch (failure: IllegalArgumentException) { complete(error("INVALID_ARGUMENT", failure.message ?: "选择数量无效")); return null }
        val allowMultiple = options.optBoolean("allowMultipleSelection", false) && requestedLimit != 1
        val maxCount = if (!allowMultiple) 1 else if (requestedLimit > 0) requestedLimit else MAX_SELECTED_MEDIA
        val pickerIntent = try { makePhotoPickerIntent(allowMultiple, requestedLimit, requireNotNull(normalizedMediaType)) }
        catch (throwable: IllegalArgumentException) { complete(error("INVALID_ARGUMENT", throwable.message ?: "选择数量无效")); return null }
        if (!hasActivityHandler(activity, pickerIntent)) {
            complete(error("UNAVAILABLE", "设备没有可处理图片选择请求的 Activity"))
            return null
        }

        return PendingRequest(
            requestId = UUID.randomUUID().toString(),
            activityReference = WeakReference(activity),
            requestCode = nextRequestCode(),
            kind = RequestKind.PICK_IMAGES,
            intent = pickerIntent,
            outputUri = null,
            maxCount = maxCount,
            complete = complete,
            resultMode = ResultMode.MODERN_GALLERY,
            includeMetadata = options.optBoolean("includeMetadata", false),
            mediaType = requireNotNull(normalizedMediaType),
        )
    }

    private fun makePhotoPickerIntent(allowMultiple: Boolean, limit: Int = 1, mediaType: Int = 0): Intent {
        val maximum = if (limit == 0) MAX_SELECTED_MEDIA else limit
        val multiple = allowMultiple && maximum > 1
        val mimeTypes = when (mediaType) { 0 -> arrayOf("image/*"); 1 -> arrayOf("video/*"); else -> arrayOf("image/*", "video/*") }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return Intent(MediaStore.ACTION_PICK_IMAGES).apply {
                if (mimeTypes.size == 1) type = mimeTypes[0]
                if (multiple) {
                    val systemMax = MediaStore.getPickImagesMaxLimit()
                    require(maximum <= systemMax) { "当前系统最多选择 $systemMax 项媒体，请显式降低 limit" }
                    putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, maximum)
                }
            }
        }
        return Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = if (mimeTypes.size == 1) mimeTypes[0] else "*/*"
            if (mimeTypes.size > 1) putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes)
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, multiple)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
    }

    private fun processActivityResult(
        request: PendingRequest,
        resultCode: Int,
        data: Intent?,
    ): JSONObject {
        if (resultCode != Activity.RESULT_OK) {
            cleanupCameraOutput(request)
            return error("CANCELLED", "用户取消了媒体选择")
        }

        return when (request.kind) {
            RequestKind.GET_PHOTO_CAMERA_NATIVE -> processNativeCameraPhotoResult(request, data)
            RequestKind.TAKE_PHOTO -> processNativeCameraPhotoResult(request, data)
            RequestKind.GET_PHOTO_CAMERA -> processCameraPhotoResult(request)
            RequestKind.GET_PHOTO -> processPromptPhotoResult(request, data)
            RequestKind.PICK_IMAGES -> if (request.resultMode == ResultMode.MODERN_GALLERY) {
                processModernGalleryResult(request, data)
            } else {
                processPickedImagesResult(request, data)
            }
        }
    }

    private fun processCameraPhotoResult(request: PendingRequest): JSONObject {
        val uri = request.outputUri
            ?: throw CameraCaptureException("NO_MEDIA_URI", "拍照结果没有输出 URI")
        val info = readImageInfo(request, uri)
        finalizeCameraOutput(request, uri)
        return photoResult(uri, info, saved = true)
    }

    private fun processNativeCameraPhotoResult(request: PendingRequest, data: Intent?): JSONObject {
        val raw = data?.getStringExtra(EXTRA_RESULT_JSON)
            ?: throw CameraCaptureException("NO_MEDIA_RESULT", "自有拍照 Activity 没有返回结果")
        val result = runCatching { JSONObject(raw) }.getOrElse {
            throw CameraCaptureException("INVALID_MEDIA", "自有拍照 Activity 返回了无效结果")
        }
        return normalizeResult(request, result)
    }

    private fun normalizeResult(request: PendingRequest, result: JSONObject): JSONObject {
        if (request.kind != RequestKind.TAKE_PHOTO || result.has("error")) return result
        val uri = result.optString("uri").takeIf(String::isNotEmpty)
            ?: throw CameraCaptureException("NO_MEDIA_URI", "现代拍照结果没有 URI")
        return JSONObject()
            .put("type", 0)
            .put("uri", uri)
            .put("webPath", result.optString("webPath", uri))
            .put("saved", result.optBoolean("saved", false))
            .apply {
                if (request.includeMetadata) {
                    put(
                        "metadata",
                        JSONObject()
                            .put("format", result.optString("format", "jpeg"))
                            .put("resolution", "${result.optInt("width")}x${result.optInt("height")}"),
                    )
                }
            }
    }

    private fun processPromptPhotoResult(request: PendingRequest, data: Intent?): JSONObject {
        val outputUri = request.outputUri
        val cameraInfo = outputUri?.let { uri ->
            runCatching { uri to readImageInfo(request, uri) }.getOrNull()
        }
        if (cameraInfo != null) {
            finalizeCameraOutput(request, cameraInfo.first)
            return photoResult(cameraInfo.first, cameraInfo.second, saved = true)
        }

        // 用户从 chooser 进入图片选择器时，MediaStore 预留的相机 URI 必须删除。
        cleanupCameraOutput(request)
        val uri = collectUris(data, 1).firstOrNull()
            ?: throw CameraCaptureException("NO_MEDIA_URI", "图片选择器没有返回可读取的 URI")
        persistUriPermission(request, uri)
        return photoResult(uri, readImageInfo(request, uri), saved = false)
    }

    private fun processPickedImagesResult(request: PendingRequest, data: Intent?): JSONObject {
        val uris = collectUris(data, request.maxCount)
        if (uris.isEmpty()) {
            throw CameraCaptureException("NO_MEDIA_URI", "图片选择器没有返回可读取的 URI")
        }

        val budget = NativeJsonBudget()
        val photos = budget.array()
        val returnedUris = budget.array()
        uris.forEach { uri ->
            persistUriPermission(request, uri)
            val info = readImageInfo(request, uri)
            val photo = photoResult(uri, info, saved = false).apply { remove("saved") }
            budget.append(photos, photo)
            budget.append(returnedUris, uri.toString())
        }

        return JSONObject()
            .put("photos", photos)
            .put("uris", returnedUris)
    }

    private fun processModernGalleryResult(request: PendingRequest, data: Intent?): JSONObject {
        val uris = collectUris(data, request.maxCount)
        if (uris.isEmpty()) throw CameraCaptureException("NO_MEDIA_URI", "媒体选择器没有返回可读取的 URI")
        val activity = request.activityReference.get()
            ?: throw CameraCaptureException("ACTIVITY_DESTROYED", "Activity 已销毁")
        val budget = NativeJsonBudget()
        val results = budget.array()
        val returnedUris = budget.array()
        uris.forEach { uri ->
            persistUriPermission(request, uri)
            val media = NativeMediaUri.read(activity, uri, measureSize = false)
            val type = if (media.mimeType.startsWith("image/")) 0 else if (media.mimeType.startsWith("video/")) 1
                else throw CameraCaptureException("INVALID_MEDIA", "所选 URI 不是图片或视频")
            if (request.mediaType != 2 && request.mediaType != type) throw CameraCaptureException("INVALID_MEDIA", "选择器返回了与 mediaType 不一致的媒体")
            val result = JSONObject().put("type", type).put("mimeType", media.mimeType)
                .put("uri", uri.toString()).put("webPath", uri.toString()).put("saved", false)
                .apply { media.size?.let { put("size", it) } }
            if (type == 0 && request.includeMetadata) {
                val info = readImageInfo(request, uri)
                result.put("metadata", JSONObject().put("format", info.format)
                    .put("resolution", "${info.width}x${info.height}").apply { media.size?.let { put("size", it) } })
            } else if (request.includeMetadata) {
                result.put("metadata", JSONObject().put("format", media.mimeType.substringAfter('/'))
                    .apply { media.size?.let { put("size", it) } })
            }
            budget.append(results, result)
            budget.append(returnedUris, uri.toString())
        }
        return JSONObject().put("results", results).put("uris", returnedUris)
    }

    private fun photoResult(uri: Uri, info: ImageInfo, saved: Boolean): JSONObject = JSONObject()
        .put("uri", uri.toString())
        .put("path", uri.toString())
        .put("webPath", uri.toString())
        .put("format", info.format)
        .put("width", info.width)
        .put("height", info.height)
        .put("saved", saved)

    private fun readImageInfo(request: PendingRequest, uri: Uri): ImageInfo {
        val activity = request.activityReference.get()
            ?: throw CameraCaptureException("ACTIVITY_DESTROYED", "Activity 已销毁，无法读取媒体")
        if (activity.isFinishing || activity.isDestroyed) {
            throw CameraCaptureException("ACTIVITY_DESTROYED", "Activity 已销毁，无法读取媒体")
        }
        val resolver = activity.contentResolver
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        val decoded = resolver.openInputStream(uri)?.use { stream ->
            BitmapFactory.decodeStream(stream, null, bounds)
        }
        if (decoded == null && (bounds.outWidth <= 0 || bounds.outHeight <= 0)) {
            throw CameraCaptureException("IO", "无法读取图片 URI: $uri")
        }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            throw CameraCaptureException("INVALID_MEDIA", "URI 不是可读取的图片: $uri")
        }

        val size = runCatching {
            resolver.openAssetFileDescriptor(uri, "r")?.use { it.length }
        }.getOrNull()?.takeIf { it >= 0L }
        return ImageInfo(
            width = bounds.outWidth,
            height = bounds.outHeight,
            format = imageFormat(activity, uri),
            size = size,
        )
    }

    private fun imageFormat(activity: Activity, uri: Uri): String {
        val mimeType = activity.contentResolver.getType(uri)?.lowercase(Locale.US)
        if (mimeType?.startsWith("image/") == true) return mimeType.substringAfter('/')

        val displayName = runCatching {
            activity.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        }.getOrNull()
        return (displayName ?: uri.lastPathSegment.orEmpty())
            .substringAfterLast('.', "unknown")
            .lowercase(Locale.US)
            .ifBlank { "unknown" }
    }

    private fun collectUris(data: Intent?, maxCount: Int): List<Uri> {
        if (data == null) return emptyList()
        val result = LinkedHashSet<Uri>()
        val budget = NativeJsonBudget()
        fun add(uri: Uri?) {
            if (uri == null || uri in result) return
            if (result.size >= maxCount) throw CameraCaptureException("INVALID_MEDIA", "选择结果超过请求的数量限制")
            budget.account(uri.toString())
            result.add(uri)
        }
        data.clipData?.let { clip -> for (index in 0 until clip.itemCount) add(clip.getItemAt(index).uri) }
        add(data.data)
        return result.toList()
    }

    private fun createCameraOutputUri(activity: Activity): Uri? {
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "lynx-camera-${UUID.randomUUID()}.jpg")
            put(MediaStore.Images.Media.MIME_TYPE, CAMERA_MIME_TYPE)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.Images.Media.RELATIVE_PATH, CAMERA_RELATIVE_PATH)
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
        }
        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }
        return runCatching { activity.contentResolver.insert(collection, values) }.getOrNull()
    }

    private fun finalizeCameraOutput(request: PendingRequest, uri: Uri) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val activity = request.activityReference.get()
            ?: throw CameraCaptureException("ACTIVITY_DESTROYED", "Activity 已销毁，无法提交拍照结果")
        val updated = activity.contentResolver.update(
            uri,
            ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) },
            null,
            null,
        )
        if (updated <= 0) {
            throw CameraCaptureException("IO", "无法提交 MediaStore 拍照结果")
        }
    }

    private fun cleanupCameraOutput(request: PendingRequest) {
        val activity = request.activityReference.get() ?: return
        cleanupUri(activity, request.outputUri)
    }

    private fun cleanupUri(activity: Activity, uri: Uri?) {
        if (uri == null) return
        runCatching { activity.contentResolver.delete(uri, null, null) }
    }

    /** Android 12 及以下的 ACTION_OPEN_DOCUMENT 结果需要主动持久化读取授权。 */
    private fun persistUriPermission(request: PendingRequest, uri: Uri) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
        val activity = request.activityReference.get() ?: return
        runCatching {
            activity.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }

    private fun complete(request: PendingRequest, result: JSONObject) {
        request.owner?.disown(request)
        val deliver = Runnable { runCatching { request.complete(result) } }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            deliver.run()
        } else {
            mainHandler.post(deliver)
        }
    }

    private fun hasActivityHandler(activity: Activity, intent: Intent): Boolean =
        intent.resolveActivity(activity.packageManager) != null

    private fun nextRequestCode(): Int = requestCode.getAndUpdate { current ->
        if (current >= REQUEST_CODE_END) REQUEST_CODE_START else current + 1
    }

    private fun error(code: String, message: String): JSONObject = JSONObject()
        .put("error", JSONObject().put("code", code).put("message", message))

    private class CameraCaptureException(
        val code: String,
        message: String,
    ) : Exception(message)

    private data class ImageInfo(
        val width: Int,
        val height: Int,
        val format: String,
        val size: Long?,
    )

    private data class PendingRequest(
        val requestId: String,
        val activityReference: WeakReference<Activity>,
        val requestCode: Int,
        val kind: RequestKind,
        val intent: Intent,
        val outputUri: Uri?,
        val maxCount: Int,
        val complete: (JSONObject) -> Unit,
        val resultMode: ResultMode = ResultMode.LEGACY,
        val includeMetadata: Boolean = false,
        val mediaType: Int = 0,
        val owner: NativeOwnerScope? = NativeCallContext.owner,
    )

    private enum class RequestKind {
        GET_PHOTO,
        GET_PHOTO_CAMERA,
        GET_PHOTO_CAMERA_NATIVE,
        TAKE_PHOTO,
        PICK_IMAGES,
    }

    private enum class ResultMode {
        LEGACY,
        MODERN_GALLERY,
    }

    private const val METHOD_GET_PHOTO = "getPhoto"
    private const val METHOD_PICK_IMAGES = "pickImages"
    private const val METHOD_CHOOSE_FROM_GALLERY = "chooseFromGallery"
    private const val METHOD_TAKE_PHOTO = "takePhoto"
    private const val SOURCE_CAMERA = "CAMERA"
    private const val SOURCE_PHOTOS = "PHOTOS"
    private const val SOURCE_PROMPT = "PROMPT"
}
