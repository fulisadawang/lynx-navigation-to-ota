package com.example.lynxshell.bridge

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Base64
import com.lynx.jsbridge.Arguments
import com.lynx.react.bridge.Callback
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * LynxShellModule 的媒体实现。
 *
 * JS 只看见 `NativeModules.LynxShellModule`；本类只是 Android 宿主内部适配层，
 * 不依赖 sparkling-method、spkPipe、autolink 或 codegen。
 */
internal object ShellMediaBridge {
    private const val MAX_FILE_BYTES = 20L * 1024L * 1024L
    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker = Executors.newCachedThreadPool()
    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        .build()

    fun chooseMedia(context: Context, optionsJson: String, callback: Callback) {
        val options = runCatching { decode(optionsJson) }
            .getOrElse {
                invoke(callback, failure(it.message ?: "媒体参数不是合法 JSON Object"))
                return
            }
        if (!ShellMediaPickerCoordinator.begin(callback)) {
            invoke(callback, failure("已有媒体选择器正在显示"))
            return
        }

        val intent = Intent(context, ShellMediaPickerActivity::class.java)
            .putExtra(ShellMediaPickerActivity.EXTRA_OPTIONS_JSON, options.toString())
        if (context !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { context.startActivity(intent) }
            .onFailure {
                ShellMediaPickerCoordinator.failure(it.message ?: "无法打开系统媒体选择器")
            }
    }

    fun upload(optionsJson: String, callback: Callback) {
        worker.execute {
            val result = runCatching {
                val options = decode(optionsJson)
                val rawUrl = options.requireHttpUrl("url")
                val file = fileFromPath(options.optString("filePath"))
                require(file.isFile && file.canRead()) { "上传文件不存在或无法读取" }
                require(file.length() <= MAX_FILE_BYTES) { "上传文件超过 20 MB 限制" }

                val fieldName = safeMultipartToken(options.optString("name", "file"))
                val fileName = safeMultipartToken(
                    options.optString("fileName").ifBlank { file.name },
                )
                val mediaType = options.optString("mimeType", "application/octet-stream")
                    .toMediaTypeOrNull()
                val body = MultipartBody.Builder()
                    .setType(MultipartBody.FORM)
                    .addFormDataPart(fieldName, fileName, file.asRequestBody(mediaType))
                    .build()
                val requestBuilder = Request.Builder().url(rawUrl).post(body)
                options.optJSONObject("header")?.let { headers ->
                    headers.keys().forEach { key ->
                        requestBuilder.header(key, headers.opt(key)?.toString().orEmpty())
                    }
                }

                httpClient.newCall(requestBuilder.build()).execute().use { response ->
                    val responseText = response.body?.string().orEmpty()
                    require(response.isSuccessful) { "上传失败，HTTP ${response.code}" }
                    success(
                        hashMapOf(
                            "url" to rawUrl,
                            "clientCode" to 0,
                            "response" to responseObject(responseText),
                        ),
                    )
                }
            }.getOrElse { failure(it.message ?: "上传失败") }
            invoke(callback, result)
        }
    }

    fun download(context: Context, optionsJson: String, callback: Callback) {
        worker.execute {
            val result = runCatching {
                val options = decode(optionsJson)
                val rawUrl = options.requireHttpUrl("url")
                val extension = safeExtension(options.optString("extension")) ?: "bin"
                val request = Request.Builder().url(rawUrl).get().build()

                httpClient.newCall(request).execute().use { response ->
                    require(response.isSuccessful) { "下载失败，HTTP ${response.code}" }
                    val body = requireNotNull(response.body) { "下载响应为空" }
                    val contentLength = body.contentLength()
                    require(contentLength < 0 || contentLength <= MAX_FILE_BYTES) {
                        "下载文件超过 20 MB 限制"
                    }

                    val directory = File(context.cacheDir, "lynx-downloads").apply { mkdirs() }
                    val output = File(directory, "lynx-download-${UUID.randomUUID()}.$extension")
                    body.byteStream().use { input ->
                        output.outputStream().use { stream ->
                            copyWithLimit(input, stream, MAX_FILE_BYTES)
                        }
                    }
                    success(
                        hashMapOf(
                            "httpCode" to response.code,
                            "clientCode" to 0,
                            "filePath" to Uri.fromFile(output).toString(),
                        ),
                    )
                }
            }.getOrElse { failure(it.message ?: "下载失败") }
            invoke(callback, result)
        }
    }

    fun saveDataUrl(context: Context, optionsJson: String, callback: Callback) {
        worker.execute {
            val result = runCatching {
                val options = decode(optionsJson)
                val dataUrl = options.optString("dataURL")
                val commaIndex = dataUrl.indexOf(',')
                require(commaIndex > 0 && dataUrl.substring(0, commaIndex).contains(";base64")) {
                    "dataURL 必须是合法的 Base64 Data URL"
                }
                val encoded = dataUrl.substring(commaIndex + 1)
                require(encoded.length <= MAX_FILE_BYTES * 2) { "Data URL 超过 20 MB 限制" }
                val bytes = Base64.decode(encoded, Base64.DEFAULT)
                require(bytes.size <= MAX_FILE_BYTES) { "Data URL 超过 20 MB 限制" }

                val rawName = options.optString("filename", "lynx-file")
                val safeName = rawName.replace(Regex("[^A-Za-z0-9._-]"), "_")
                    .ifBlank { "lynx-file" }
                val extension = safeExtension(options.optString("extension")) ?: "bin"
                val directory = File(context.cacheDir, "lynx-data-url").apply { mkdirs() }
                val output = File(directory, "$safeName.$extension")
                output.writeBytes(bytes)
                success(hashMapOf("filePath" to Uri.fromFile(output).toString()))
            }.getOrElse { failure(it.message ?: "Data URL 落盘失败") }
            invoke(callback, result)
        }
    }

    internal fun success(data: HashMap<String, Any>): HashMap<String, Any> =
        hashMapOf("code" to 0, "msg" to "ok", "data" to data)

    internal fun failure(message: String): HashMap<String, Any> =
        hashMapOf("code" to -1, "msg" to message)

    internal fun invoke(callback: Callback, value: HashMap<String, Any>) {
        // Lynx Callback 只接受 JavaOnlyMap/JavaOnlyArray 等 Bridge 类型；普通 HashMap
        // 会导致 JS 回调收到 null。Arguments 会递归编码媒体列表、响应对象等嵌套数据。
        mainHandler.post { callback.invoke(Arguments.makeNativeMap(value)) }
    }

    private fun decode(json: String): JSONObject {
        val value = JSONTokener(json).nextValue()
        require(value is JSONObject) { "media options 必须是 JSON Object" }
        return value
    }

    private fun JSONObject.requireHttpUrl(key: String): String {
        val value = optString(key).trim()
        val scheme = Uri.parse(value).scheme?.lowercase()
        require(value.isNotBlank() && scheme in setOf("http", "https")) { "$key 不是合法 HTTP(S) URL" }
        return value
    }

    private fun fileFromPath(value: String): File {
        require(value.isNotBlank()) { "filePath 不能为空" }
        val uri = Uri.parse(value)
        return if (uri.scheme.equals("file", ignoreCase = true)) {
            File(requireNotNull(uri.path) { "filePath 无效" })
        } else {
            File(value)
        }
    }

    private fun safeMultipartToken(value: String): String =
        value.replace(Regex("[\"\\r\\n]"), "_").ifBlank { "file" }

    private fun safeExtension(value: String?): String? {
        val trimmed = value.orEmpty().trim().trimStart('.')
        return trimmed.takeIf { Regex("^[A-Za-z0-9]{1,10}$").matches(it) }?.lowercase()
    }

    private fun responseObject(value: String): Any {
        if (value.isBlank()) return hashMapOf<String, Any>()
        return runCatching { bridgeValue(JSONTokener(value).nextValue()) }
            .getOrElse { value }
    }

    private fun bridgeValue(value: Any?): Any = when (value) {
        null, JSONObject.NULL -> ""
        is JSONObject -> hashMapOf<String, Any>().apply {
            value.keys().forEach { key -> put(key, bridgeValue(value.opt(key))) }
        }
        is JSONArray -> arrayListOf<Any>().apply {
            for (index in 0 until value.length()) add(bridgeValue(value.opt(index)))
        }
        else -> value
    }

    private fun copyWithLimit(
        input: java.io.InputStream,
        output: java.io.OutputStream,
        limit: Long,
    ) {
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        var total = 0L
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            total += count
            require(total <= limit) { "文件超过 20 MB 限制" }
            output.write(buffer, 0, count)
        }
    }
}

/** 选择器 Activity 与 NativeModule 之间的一次性回调通道。 */
internal object ShellMediaPickerCoordinator {
    private var callback: Callback? = null

    @Synchronized
    fun begin(value: Callback): Boolean {
        if (callback != null) return false
        callback = value
        return true
    }

    @Synchronized
    fun hasPending(): Boolean = callback != null

    fun success(data: HashMap<String, Any>) {
        take()?.let { ShellMediaBridge.invoke(it, ShellMediaBridge.success(data)) }
    }

    fun failure(message: String) {
        take()?.let { ShellMediaBridge.invoke(it, ShellMediaBridge.failure(message)) }
    }

    @Synchronized
    private fun take(): Callback? = callback.also { callback = null }
}
