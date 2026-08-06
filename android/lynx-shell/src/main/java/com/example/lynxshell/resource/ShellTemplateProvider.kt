package com.example.lynxshell.resource

import android.content.Context
import com.example.lynxshell.BuildConfig
import com.lynx.tasm.provider.AbsTemplateProvider
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Lynx Bundle 的唯一加载入口。
 *
 * - assets:// 与 Explorer 的 file://lynx?local:// 走 APK assets。
 * - https:// 走 OkHttp，不限制 Host。
 * - http:// 仅 Debug 且页面明确允许时开放。
 * - 路径、响应码、最终重定向协议和最大体积都必须通过校验。
 * - Activity 重试或销毁时调用 [close]，旧请求不会再回调已销毁的 LynxView。
 */
class ShellTemplateProvider(
    context: Context,
    private val allowHttpInDebug: Boolean = false,
    private val onLoadError: ((url: String, message: String) -> Unit)? = null,
    /** prepareRoute 命中时只消费一次；URL 不匹配会继续走正常 Provider。 */
    private val preparedUrl: String? = null,
    private val preparedBytes: ByteArray? = null,
    /** ActivityBundleRuntime 返回的已校验文件；绝对路径不会从 Intent 进入。 */
    private val preparedFile: File? = null,
) : AbsTemplateProvider(), AutoCloseable {
    private val appContext = context.applicationContext
    private val closed = AtomicBoolean(false)
    private val preparedConsumed = AtomicBoolean(false)
    private val activeCalls = ConcurrentHashMap.newKeySet<Call>()

    override fun loadTemplate(uri: String, callback: Callback) {
        if (closed.get()) return
        ioExecutor.execute {
            if (
                (preparedBytes != null || preparedFile != null) &&
                uri == preparedUrl &&
                preparedConsumed.compareAndSet(false, true)
            ) {
                runCatching {
                    preparedBytes ?: loadFile(requireNotNull(preparedFile))
                }.onSuccess { bytes ->
                    if (!closed.get()) callback.onSuccess(bytes)
                }.onFailure { error ->
                    if (!closed.get()) {
                        val message = error.message ?: "已准备 Bundle 读取失败"
                        callback.onFailed(message)
                        onLoadError?.invoke(uri, message)
                    }
                }
                return@execute
            }
            runCatching { load(uri) }
                .onSuccess { bytes ->
                    if (!closed.get()) callback.onSuccess(bytes)
                }
                .onFailure { error ->
                    if (closed.get()) return@onFailure
                    val message = error.message ?: "Bundle 加载失败"
                    callback.onFailed(message)
                    onLoadError?.invoke(uri, message)
                }
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        activeCalls.forEach(Call::cancel)
        activeCalls.clear()
    }

    private fun load(uri: String): ByteArray = when {
        uri.startsWith("https://", ignoreCase = true) -> loadRemote(uri)
        uri.startsWith("http://", ignoreCase = true) -> {
            require(BuildConfig.DEBUG && allowHttpInDebug) { "明文 HTTP Bundle 已被宿主拒绝" }
            loadRemote(uri)
        }
        else -> loadAsset(uri)
    }

    private fun loadAsset(uri: String): ByteArray {
        val path = normalizeAssetPath(uri)
        require(path.isNotBlank()) { "本地 Bundle 路径为空" }
        require(!path.startsWith("/") && path.split('/').none { it == ".." }) {
            "本地 Bundle 路径不安全: $path"
        }

        val candidates = if ('/' in path) listOf(path) else listOf(path, "bundles/$path")
        val input = candidates.firstNotNullOfOrNull { candidate ->
            runCatching { appContext.assets.open(candidate) }.getOrNull()
        } ?: throw IllegalArgumentException("APK assets 中未找到 Bundle: $path")

        return input.use {
            ByteArrayOutputStream().use { output ->
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                var total = 0L
                while (true) {
                    check(!closed.get()) { "Bundle 加载已取消" }
                    val count = it.read(buffer)
                    if (count < 0) break
                    total += count
                    require(total <= MAX_BUNDLE_BYTES) { "Bundle 超过 ${MAX_BUNDLE_BYTES / 1024 / 1024}MB 限制" }
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
        }
    }

    /** 只读取 OTA runtime 已校验的普通文件，并再次检查大小与空文件边界。 */
    private fun loadFile(file: File): ByteArray {
        require(file.isFile && file.canRead()) { "已准备的 Bundle 不可读: ${file.absolutePath}" }
        require(file.length() <= MAX_BUNDLE_BYTES) {
            "Bundle 超过 ${MAX_BUNDLE_BYTES / 1024 / 1024}MB 限制"
        }
        FileInputStream(file).use { input ->
            return ByteArrayOutputStream().use { output ->
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                var total = 0L
                while (true) {
                    check(!closed.get()) { "Bundle 加载已取消" }
                    val count = input.read(buffer)
                    if (count < 0) break
                    total += count
                    require(total <= MAX_BUNDLE_BYTES) {
                        "Bundle 超过 ${MAX_BUNDLE_BYTES / 1024 / 1024}MB 限制"
                    }
                    output.write(buffer, 0, count)
                }
                output.toByteArray().also { bytes ->
                    require(bytes.isNotEmpty()) { "Bundle 内容为空" }
                }
            }
        }
    }

    private fun loadRemote(uri: String): ByteArray {
        val request = Request.Builder().url(uri).get().build()

        val call = httpClient.newCall(request)
        activeCalls += call
        try {
            call.execute().use { response ->
                val finalUrl = response.request.url
                require(response.isSuccessful) { "Bundle HTTP 状态码异常: ${response.code}" }
                require(
                    finalUrl.scheme == "https" ||
                        (BuildConfig.DEBUG && allowHttpInDebug && finalUrl.scheme == "http"),
                ) { "Bundle 重定向到了不安全协议: ${finalUrl.scheme}" }
                val body = requireNotNull(response.body) { "Bundle 响应体为空" }
                val declaredLength = body.contentLength()
                require(declaredLength < 0 || declaredLength <= MAX_BUNDLE_BYTES) {
                    "Bundle Content-Length 超过限制"
                }
                val bytes = body.bytes()
                require(bytes.isNotEmpty()) { "Bundle 内容为空" }
                require(bytes.size <= MAX_BUNDLE_BYTES) { "Bundle 实际大小超过限制" }
                return bytes
            }
        } finally {
            activeCalls -= call
        }
    }

    private fun normalizeAssetPath(uri: String): String {
        val raw = when {
            uri.startsWith(ASSET_PREFIX, ignoreCase = true) -> uri.substring(ASSET_PREFIX.length)
            uri.startsWith(EXPLORER_LOCAL_PREFIX, ignoreCase = true) -> uri.substring(EXPLORER_LOCAL_PREFIX.length)
            else -> uri
        }
        var path = raw.substringBefore('?').substringBefore('#').removePrefix("/").replace('\\', '/')
        while (path.startsWith("./")) path = path.removePrefix("./")
        return path
    }

    companion object {
        private const val ASSET_PREFIX = "assets://"
        private const val EXPLORER_LOCAL_PREFIX = "file://lynx?local://"
        private const val MAX_BUNDLE_BYTES = 20L * 1024L * 1024L

        private val ioExecutor: ExecutorService = Executors.newCachedThreadPool { runnable ->
            Thread(runnable, "lynx-template-loader").apply { isDaemon = true }
        }

        private val httpClient: OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .followRedirects(true)
            .build()

        /**
         * prepareRoute 与真实页面加载复用完全相同的协议、域名、重定向和体积校验。
         *
         * 回调运行在 Provider IO 线程；NativeModule 必须切回主线程后再触发 JS callback。
         */
        fun prefetch(
            context: Context,
            uri: String,
            allowHttpInDebug: Boolean,
            callback: (Result<ByteArray>) -> Unit,
        ) {
            val provider = ShellTemplateProvider(
                context = context.applicationContext,
                allowHttpInDebug = allowHttpInDebug,
            )
            ioExecutor.execute {
                val result = runCatching { provider.load(uri) }
                provider.close()
                callback(result)
            }
        }
    }
}
