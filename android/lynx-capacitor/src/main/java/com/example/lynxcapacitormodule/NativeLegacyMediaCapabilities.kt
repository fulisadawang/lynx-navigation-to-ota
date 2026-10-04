package com.example.lynxcapacitormodule

import android.app.Activity
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.webkit.MimeTypeMap
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener

/** Shell 旧五方法的协议适配；选择/下载复用 Cap backend，上传和落盘使用同一有界 IO/owner。 */
internal object NativeLegacyMediaCapabilities {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val largeDataUrlBusy = AtomicBoolean(false)
    const val MAX_DATA_URL_CHARS = ((20 * 1024 * 1024 + 2) / 3) * 4 + 4096

    class DataUrlAdmission {
        private val released = AtomicBoolean(false)
        fun release() { if (released.compareAndSet(false, true)) largeDataUrlBusy.set(false) }
    }
    fun admitDataUrl(): DataUrlAdmission? = if (largeDataUrlBusy.compareAndSet(false, true)) DataUrlAdmission() else null

    fun dispatch(activity: Activity, method: String, optionsJSON: String, complete: (JSONObject) -> Unit) {
        val limit = if (method == "saveDataURL") MAX_DATA_URL_CHARS else NativePayloadBudget.REQUEST_BYTES
        require(optionsJSON.length <= limit) { "媒体参数超过输入预算" }
        if (method != "saveDataURL") NativePayloadBudget.check(optionsJSON.toByteArray(Charsets.UTF_8).size.toLong(), limit.toLong())
        val options = JSONTokener(optionsJSON).nextValue() as? JSONObject
            ?: throw IllegalArgumentException("media options 必须是 JSON Object")
        when (method) {
            "chooseMedia" -> choose(activity, options, complete)
            "uploadFile", "uploadImage" -> {
                val media = NativeMediaUri.resolve(activity, options.optString("filePath"), options.optString("directory", "CACHE"))
                NativeIO.network.submit(NativeCallContext.owner, { complete(failure("网络执行队列已满")) }) {
                    val result = try { success(upload(activity, options, media)) }
                    catch (error: Exception) { failure(error.message ?: "上传失败") }
                    complete(result)
                }
            }
            "downloadFile" -> {
                val extension = extension(options.optString("extension"))
                val downloadOptions = JSONObject(options.toString()).put("path", "lynx-downloads/lynx-download-${UUID.randomUUID()}.$extension")
                    .put("directory", "CACHE")
                NativeFileTransferCapabilities.dispatch(activity, "downloadFile", downloadOptions, { result ->
                    if (result.has("error")) complete(fromNative(result))
                    else complete(success(JSONObject().put("httpCode", result.getInt("httpCode")).put("clientCode", 0)
                        .put("filePath", Uri.fromFile(File(result.getString("path"))).toString())))
                })
            }
            "saveDataURL" -> complete(success(saveDataUrl(activity, options)))
            else -> complete(failure("未知媒体方法 $method"))
        }
    }

    private fun choose(activity: Activity, options: JSONObject, complete: (JSONObject) -> Unit) {
        val types = options.optJSONArray("mediaTypes")?.let { array ->
            (0 until array.length()).map { array.optString(it) }.filter { it in setOf("image", "video") }.toSet()
        }.orEmpty().ifEmpty { setOf("image") }
        val camera = options.optString("sourceType", "album") == "camera"
        val count = NativeCameraCaptureCapabilities.readSelectionCount(options, "count", 1, minimum = 1)
        val limit = NativeCameraCaptureCapabilities.readSelectionCount(options, "maxCount", count, minimum = 1)
        val owner = NativeCallContext.owner
        val reply: (JSONObject) -> Unit = { result ->
            if (result.has("error")) complete(fromNative(result))
            else NativeIO.local.submit(owner, { complete(failure("媒体结果执行队列已满")) }) {
                try { complete(success(legacySelection(activity, result))) }
                catch (error: Exception) { complete(failure(error.message ?: "媒体结果无效")) }
            }
        }
        onMain {
            if (owner?.isActive == false) return@onMain
            NativeCallContext.withOwner(owner) {
                if (!camera) {
                    val gallery = JSONObject().put("mediaType", if (types.size > 1) 2 else if ("video" in types) 1 else 0)
                        .put("allowMultipleSelection", limit > 1).put("limit", limit).put("includeMetadata", true)
                    NativeCameraCaptureCapabilities.dispatch(activity, "chooseFromGallery", gallery, reply)
                } else {
                    // 旧 mixed camera 一次只拍图片；纯 video 才进入录像 UI。
                    val capture = if (types == setOf("video")) "recordVideo" else "takePhoto"
                    val permission = JSONObject().put("permissions", JSONArray().put("camera"))
                    NativePermissionCoordinator.request(activity, "Camera", "requestPermissions", permission) { status ->
                        if (owner?.isActive == false) return@request
                        NativeCallContext.withOwner(owner) {
                            if (status.has("error")) reply(status)
                            else if (status.optString("camera") != "granted") complete(failure("相机权限未授予"))
                            else if (capture == "recordVideo") NativeVideoCaptureCapabilities.dispatch(activity, capture, JSONObject(), reply)
                            else NativeCameraCaptureCapabilities.dispatch(activity, capture, JSONObject(), reply)
                        }
                    }
                }
            }
        }
    }

    private fun legacySelection(activity: Activity, result: JSONObject): JSONObject {
        val selected = result.optJSONArray("results") ?: JSONArray().put(result)
        val budget = NativeJsonBudget()
        val files = budget.array()
        val materialized = mutableListOf<File>()
        try {
            for (index in 0 until selected.length()) {
                val item = selected.getJSONObject(index)
                val media = NativeMediaUri.resolve(activity, item.getString("uri"))
                require(media.mimeType.startsWith("image/") || media.mimeType.startsWith("video/")) { "结果不是图片或视频" }
                // 旧 Shell 返回真实缓存文件两种路径；新 Cap gallery 仍直接返回选中 URI。
                val output = materializeLegacyMedia(activity, media).also(materialized::add)
                val file = JSONObject().put("tempFilePath", Uri.fromFile(output).toString())
                    .put("tempFileAbsolutePath", output.absolutePath).put("size", output.length())
                    .put("mediaType", if (media.mimeType.startsWith("video/")) "video" else "image").put("mimeType", media.mimeType)
                budget.append(files, file)
            }
            return JSONObject().put("tempFiles", files)
        } catch (failure: Exception) {
            materialized.forEach { file -> NativeCallContext.owner?.disown(file); file.delete() }
            throw failure
        }
    }

    /** 成功交付后移交既有 cache 生命周期，允许结果路径传给下一个页面继续消费。 */
    fun finishSelection(result: JSONObject, delivered: Boolean, owner: NativeOwnerScope) {
        val files = result.optJSONObject("data")?.optJSONArray("tempFiles") ?: return
        for (index in 0 until files.length()) {
            val file = File(files.getJSONObject(index).getString("tempFileAbsolutePath"))
            owner.disown(file)
            if (!delivered) file.delete()
        }
    }

    private fun materializeLegacyMedia(activity: Activity, media: NativeMediaUri.Media): File {
        val directory = File(activity.cacheDir, "lynx-media")
        require(directory.isDirectory || directory.mkdirs()) { "无法创建媒体缓存目录" }
        val suffix = MimeTypeMap.getSingleton().getExtensionFromMimeType(media.mimeType)?.let(::extension) ?: "bin"
        val target = File(directory, "lynx-media-${UUID.randomUUID()}.$suffix")
        val temporary = File(directory, ".${target.name}.part")
        try {
            requireNotNull(activity.contentResolver.openInputStream(media.uri)) { "所选媒体不可读取" }.use { input ->
                FileOutputStream(temporary).use { output ->
                    NativePayloadBudget.copy(input, output, NativePayloadBudget.DOWNLOAD_BYTES)
                    output.fd.sync()
                }
            }
            NativeAtomicFile.publish(temporary, target)
            NativeCallContext.owner?.own(target) { target.delete() }
            NativeCallContext.checkActive()
            return target
        } finally { temporary.delete() }
    }

    private fun upload(activity: Activity, options: JSONObject, media: NativeMediaUri.Media): JSONObject {
        val url = URL(options.optString("url").trim())
        require(url.protocol in setOf("http", "https") && url.host.isNotBlank()) { "url 不是合法 HTTP(S) URL" }
        val field = token(options.optString("name", "file"))
        val filename = token(options.optString("fileName").ifBlank { media.file?.name ?: "lynx-media" })
        val mime = options.optString("mimeType").ifBlank { media.mimeType }
        require(Regex("^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$").matches(mime)) { "mimeType 无效" }
        val boundary = "lynx-${UUID.randomUUID()}"
        val connection = url.openConnection() as? HttpURLConnection ?: throw IllegalArgumentException("上传连接不是 HTTP")
        val owner = NativeCallContext.owner
        owner?.own(connection) { connection.disconnect() }
        try {
            NativeCallContext.checkActive()
            connection.requestMethod = "POST"
            connection.connectTimeout = 20_000
            connection.readTimeout = 60_000
            connection.doOutput = true
            connection.setChunkedStreamingMode(8192)
            options.optJSONObject("header")?.let { headers -> headers.keys().forEach { key ->
                connection.setRequestProperty(key, headers.opt(key)?.toString().orEmpty())
            } }
            connection.setRequestProperty("Content-Type", "multipart/form-data; boundary=$boundary")
            connection.outputStream.use { output ->
                val prefix = "--$boundary\r\nContent-Disposition: form-data; name=\"$field\"; filename=\"$filename\"\r\nContent-Type: $mime\r\n\r\n"
                output.write(prefix.toByteArray(Charsets.UTF_8))
                requireNotNull(activity.contentResolver.openInputStream(media.uri)) { "上传文件不可读取" }.use { input ->
                    val buffer = ByteArray(8192)
                    var total = 0L
                    while (true) {
                        NativeCallContext.checkActive()
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        NativePayloadBudget.check(total, NativePayloadBudget.DOWNLOAD_BYTES)
                        output.write(buffer, 0, count)
                    }
                }
                output.write("\r\n--$boundary--\r\n".toByteArray(Charsets.UTF_8))
            }
            NativeCallContext.checkActive()
            val code = connection.responseCode
            require(code in 200..299) { "上传失败，HTTP $code" }
            val text = connection.inputStream.use { String(NativePayloadBudget.read(it), Charsets.UTF_8) }
            val response = if (text.isBlank()) JSONObject() else try { JSONTokener(text).nextValue() ?: JSONObject.NULL } catch (_: Exception) { text }
            return JSONObject().put("url", url.toString()).put("clientCode", 0).put("response", response)
        } finally {
            owner?.disown(connection)
            connection.disconnect()
        }
    }

    private fun saveDataUrl(activity: Activity, options: JSONObject): JSONObject {
        val dataURL = options.optString("dataURL")
        val comma = dataURL.indexOf(',')
        require(comma > 0 && dataURL.substring(0, comma).startsWith("data:") && dataURL.substring(0, comma).endsWith(";base64")) { "dataURL 必须为 Base64 Data URL" }
        val encodedLength = dataURL.length - comma - 1
        require(encodedLength <= ((NativePayloadBudget.DOWNLOAD_BYTES + 2) / 3) * 4) { "Data URL 超过 20 MiB 限制" }
        NativeCallContext.checkActive()
        val bytes = Base64.decode(dataURL.substring(comma + 1), Base64.DEFAULT)
        NativePayloadBudget.check(bytes.size.toLong(), NativePayloadBudget.DOWNLOAD_BYTES)
        val name = options.optString("filename", "lynx-file").replace(Regex("[^A-Za-z0-9._-]"), "_")
            .take(128).ifBlank { "lynx-file" }
        val file = File(activity.cacheDir, "lynx-data-url/$name.${extension(options.optString("extension"))}")
        NativeAtomicFile.write(file, bytes)
        return JSONObject().put("filePath", Uri.fromFile(file).toString())
    }

    private fun token(value: String): String = value.replace(Regex("[\"\\r\\n]"), "_").take(256).ifBlank { "file" }
    private fun extension(value: String): String = value.trim().trimStart('.').takeIf { Regex("^[A-Za-z0-9]{1,10}$").matches(it) } ?: "bin"
    fun success(data: JSONObject): JSONObject = JSONObject().put("code", 0).put("msg", "ok").put("data", data)
    fun failure(message: String): JSONObject = JSONObject().put("code", -1).put("msg", message)
    private fun fromNative(result: JSONObject): JSONObject = failure(result.optJSONObject("error")?.optString("message") ?: "原生媒体操作失败")
    private fun onMain(action: () -> Unit) { if (Looper.myLooper() == Looper.getMainLooper()) action() else mainHandler.post(action) }
}
