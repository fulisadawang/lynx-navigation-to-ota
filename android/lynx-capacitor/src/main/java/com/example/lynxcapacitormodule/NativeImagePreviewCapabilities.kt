package com.example.lynxcapacitormodule

import android.app.Activity
import android.content.Intent
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import java.lang.ref.WeakReference
import java.util.UUID
import org.json.JSONObject

/** 多图列表保留在进程内，预览 Activity 只接收 requestId，始终受原调用页 owner 约束。 */
internal object NativeImagePreviewCapabilities {
    const val EXTRA_REQUEST_ID = "com.example.lynxcapacitormodule.image.PREVIEW_REQUEST_ID"
    private val mainHandler = Handler(Looper.getMainLooper())
    private val lock = Any()
    private var pending: Request? = null

    fun open(activity: Activity, options: JSONObject, complete: (JSONObject) -> Unit) {
        val items = options.optJSONArray("items")
        if (items == null || items.length() !in 1..NativeCameraCaptureCapabilities.MAX_SELECTED_MEDIA) {
            complete(error("INVALID_ARGUMENT", "items 必须为 1 到 16 张本地图片")); return
        }
        if (listOf("path", "localPath", "uri").any(options::has)) {
            complete(error("INVALID_ARGUMENT", "items 与单个 path/uri 参数不能同时传入")); return
        }
        val rawIndex = options.opt("initialIndex") ?: 0
        if (rawIndex !is Number || !rawIndex.toDouble().isFinite() || rawIndex.toDouble() % 1 != 0.0 ||
            rawIndex.toDouble() !in 0.0..(items.length() - 1).toDouble()) {
            complete(error("INVALID_ARGUMENT", "initialIndex 必须是图片列表内的整数索引")); return
        }
        val request = Request(UUID.randomUUID().toString(), NativeCallContext.owner, rawIndex.toInt(), complete)
        val accepted = synchronized(lock) { if (pending != null) false else { pending = request; true } }
        if (!accepted) { complete(error("BUSY", "已有一个原生图片预览正在进行")); return }
        request.owner?.own(request) {
            synchronized(lock) { if (pending === request) pending = null; request.complete = null }
            mainHandler.post { request.viewer.get()?.finish() }
        }
        NativeIO.local.submit(request.owner, { finish(request.id, error("BUSY", "图片读取队列已满")) }) {
            try {
                val resolved = buildList {
                    for (index in 0 until items.length()) {
                        NativeCallContext.checkActive()
                        val item = items.optJSONObject(index) ?: throw IllegalArgumentException("items 每项必须为图片参数对象")
                        require(!item.has("uri") || item.opt("uri") is String) { "图片 uri 必须为字符串" }
                        require(!item.has("path") || item.opt("path") is String) { "图片 path 必须为字符串" }
                        val raw = item.optString("uri").takeIf { it.isNotBlank() }
                            ?: item.optString("path").takeIf { it.isNotBlank() }
                            ?: throw IllegalArgumentException("每张图片需要非空 uri 或 path")
                        require(!item.has("directory") || item.opt("directory") is String) { "directory 必须为字符串" }
                        require(!item.has("mimeType") || item.opt("mimeType") is String) { "mimeType 必须为字符串" }
                        val media = NativeMediaUri.resolve(activity, raw,
                            item.optString("directory", "CACHE"), item.optString("mimeType").ifBlank { "application/octet-stream" }, measureSize = false)
                        require(media.mimeType.startsWith("image/")) { "items 只接受本地图片；视频与文档使用单个文件入口" }
                        // 仅探测真实图片头，不分配像素；文件扩展名或调用方 MIME 不能把文档变成图片。
                        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                        requireNotNull(activity.contentResolver.openInputStream(media.uri)) { "图片不可读取" }.use {
                            BitmapFactory.decodeStream(it, null, bounds)
                        }
                        require(bounds.outWidth > 0 && bounds.outHeight > 0 && bounds.outMimeType?.startsWith("image/") == true) {
                            "items 中包含非图片或无效图片文件"
                        }
                        add(media)
                    }
                }
                synchronized(lock) { if (pending !== request) return@submit; request.items = resolved }
                mainHandler.post {
                    if (request.owner?.isActive == false) return@post
                    if (activity.isDestroyed || activity.isFinishing) { finish(request.id, error("HOST_DESTROYED", "图片宿主已销毁")); return@post }
                    try {
                        NativeCallContext.withOwner(request.owner) {
                            activity.startActivity(Intent(activity, ImagePreviewActivity::class.java).putExtra(EXTRA_REQUEST_ID, request.id))
                        }
                    } catch (failure: Exception) { finish(request.id, error("UNAVAILABLE", failure.message ?: "无法启动原生图片预览")) }
                }
            } catch (failure: Exception) {
                finish(request.id, error(if (failure is NativeCallCancelled) "HOST_DESTROYED" else "INVALID_ARGUMENT", failure.message ?: "图片列表不可读取"))
            }
        }
    }

    internal data class Session(val owner: NativeOwnerScope?, val items: List<NativeMediaUri.Media>, val initialIndex: Int)
    internal fun attach(id: String, activity: ImagePreviewActivity): Session? = synchronized(lock) {
        val request = pending?.takeIf { it.id == id && it.owner?.isActive != false } ?: return@synchronized null
        if (request.items.isEmpty()) return@synchronized null
        request.viewer = WeakReference(activity)
        Session(request.owner, request.items, request.initialIndex)
    }
    internal fun ready(id: String) {
        val pair = synchronized(lock) {
            val request = pending?.takeIf { it.id == id && it.owner?.isActive != false } ?: return
            val callback = request.complete ?: return
            request.complete = null
            callback to JSONObject().put("opened", true).put("uri", request.items[request.initialIndex].uri.toString())
                .put("mimeType", request.items[request.initialIndex].mimeType)
                .put("initialIndex", request.initialIndex).put("itemCount", request.items.size)
        }
        mainHandler.post { pair.first(pair.second) }
    }
    internal fun finish(id: String, result: JSONObject = error("CANCELLED", "原生图片预览已关闭")) {
        val request = synchronized(lock) {
            pending?.takeIf { it.id == id }?.also { pending = null }
        } ?: return
        request.owner?.disown(request)
        val callback = synchronized(lock) { request.complete.also { request.complete = null } }
        if (callback != null) mainHandler.post { callback(result) }
    }
    private fun error(code: String, message: String): JSONObject = JSONObject().put("error", JSONObject().put("code", code).put("message", message))
    private class Request(val id: String, val owner: NativeOwnerScope?, val initialIndex: Int,
        var complete: ((JSONObject) -> Unit)?) {
        var items: List<NativeMediaUri.Media> = emptyList()
        var viewer: WeakReference<ImagePreviewActivity> = WeakReference(null)
    }
}
