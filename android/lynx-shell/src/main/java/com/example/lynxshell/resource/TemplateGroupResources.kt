package com.example.lynxshell.resource

import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.lynx.tasm.TemplateBundle
import com.lynx.tasm.group.ILynxViewGroup
import com.lynx.tasm.provider.AbsTemplateProvider
import com.lynx.tasm.resourceprovider.LynxResourceCallback
import com.lynx.tasm.resourceprovider.LynxResourceRequest
import com.lynx.tasm.resourceprovider.LynxResourceResponse
import com.lynx.tasm.resourceprovider.generic.LynxGenericResourceFetcher
import com.lynx.tasm.resourceprovider.media.LynxMediaResourceFetcher
import com.lynx.tasm.resourceprovider.media.OptionalBool
import com.lynx.tasm.resourceprovider.template.LynxTemplateResourceFetcher
import com.lynx.tasm.resourceprovider.template.TemplateProviderResult
import com.ota.android.sdk.OtaSidecarModels
import com.ota.android.sdk.OtaSidecarViewResources
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import java.lang.ref.WeakReference

/** Group 只持固定 adapter 与解析模板；Provider/附属资源仅在当前页面租借期间绑定。 */
internal class TemplateGroupResources(private val mainUrl: String, private val mainSha: String) {
    private class Binding(val provider: ShellTemplateProvider, val sidecars: OtaSidecarViewResources?)
    @Volatile private var binding: Binding? = null
    private val pending = mutableSetOf<() -> Unit>()
    private val synchronousReads = AtomicInteger()
    private var group = WeakReference<ILynxViewGroup>(null)
    fun attachGroup(value: ILynxViewGroup) { group = WeakReference(value) }
    // 不记录页面数据；计数供运行态诊断辨别实际本地读取。
    val requestCounts = ConcurrentHashMap<String, AtomicInteger>()
    fun bind(provider: ShellTemplateProvider, sidecars: OtaSidecarViewResources?) {
        check(binding == null && pending.isEmpty()) { "引擎 slot 仍有活体页面" }
        binding = Binding(provider, sidecars)
    }
    fun unbind(): Boolean {
        val drained = pending.isEmpty() && synchronousReads.get() == 0
        binding = null
        pending.toList().forEach { cancel ->
            try { cancel() } catch (error: Throwable) {
                // 页面已关闭，SDK 响应异常不能中断其余取消；不输出 URL 或页面数据。
                Log.w("LynxTemplateGroup", "资源关闭响应异常：${error.javaClass.simpleName}")
            }
        }
        return drained
    }

    private fun <T : Any> enqueue(callback: LynxResourceCallback<T>,
        action: (Binding, (Result<T>) -> Unit) -> Unit) {
        val captured = binding
        main.post {
            if (captured == null || binding !== captured) {
                fail(callback, "引擎资源租约已关闭")
                return@post
            }
            var completed = false
            lateinit var cancel: () -> Unit
            val deliver: (Result<T>) -> Unit = { result ->
                val finish: () -> Unit = {
                    if (completed) {
                        (result.getOrNull() as? TemplateProviderResult)?.templateBundle?.release()
                    } else {
                        completed = true
                        pending.remove(cancel)
                        result.fold(
                            onSuccess = {
                                callback.onResponse(LynxResourceResponse.onSuccess(it))
                            },
                            onFailure = { fail(callback, it.message ?: "引擎资源读取失败") },
                        )
                    }
                }
                if (Looper.myLooper() == Looper.getMainLooper()) finish() else main.post(finish)
            }
            cancel = { deliver(Result.failure(IOException("引擎资源租约已关闭"))) }
            pending.add(cancel)
            action(captured, deliver)
        }
    }

    val template = object : LynxTemplateResourceFetcher() {
        override fun fetchTemplate(request: LynxResourceRequest, callback: LynxResourceCallback<TemplateProviderResult>) {
            if (request.url != mainUrl && request.asyncMode != LynxResourceRequest.AsyncMode.EXACTLY_ASYNC) {
                synchronousReads.incrementAndGet()
                val captured = binding
                try {
                    requestCounts.getOrPut(request.url) { AtomicInteger() }.incrementAndGet()
                    val result = runCatching {
                        val entry = captured?.sidecars?.resource(request.url)
                            ?: throw IOException("当前代码 lease 未声明动态组件：${request.url}")
                        require(entry.kind == OtaSidecarModels.AsyncKind.BUNDLE) { "资源类型不是 Bundle" }
                        TemplateProviderResult.fromBinary(verifiedBytes(entry))
                    }
                    if (captured == null || binding !== captured) fail(callback, "引擎资源租约已关闭")
                    else result.fold({ callback.onResponse(LynxResourceResponse.onSuccess(it)) },
                        { fail(callback, it.message ?: "引擎动态组件读取失败") })
                } finally { synchronousReads.decrementAndGet() }
                return
            }
            enqueue(callback) { captured, deliver ->
                requestCounts.getOrPut(request.url) { AtomicInteger() }.incrementAndGet()
                if (request.url == mainUrl) {
                    group.get()?.takeIf { it.isTemplateBundleReady }?.templateBundleNonBlocking?.let { bundle ->
                        deliver(Result.success(TemplateProviderResult.fromTemplateBundle(bundle)))
                        return@enqueue
                    }
                    captured.provider.loadTemplate(mainUrl, object : AbsTemplateProvider.Callback {
                        override fun onSuccess(data: ByteArray) {
                            deliver(runCatching {
                                check(sha256(data) == mainSha) { "引擎主 Bundle SHA256 与准备来源不符" }
                                val bundle = TemplateBundle.fromTemplate(data)
                                if (!bundle.isValid) {
                                    val message = bundle.errorMessage
                                    bundle.release()
                                    throw IOException("引擎主 Bundle 解码失败：$message")
                                }
                                TemplateProviderResult.fromTemplateBundle(bundle)
                            })
                        }
                        override fun onFailed(message: String) { deliver(Result.failure(IOException(message))) }
                    })
                } else io.execute {
                    deliver(runCatching {
                        val entry = captured.sidecars?.resource(request.url)
                            ?: throw IOException("当前代码 lease 未声明动态组件：${request.url}")
                        require(entry.kind == OtaSidecarModels.AsyncKind.BUNDLE) { "资源类型不是 Bundle" }
                        TemplateProviderResult.fromBinary(verifiedBytes(entry))
                    })
                }
            }
        }
        override fun fetchSSRData(request: LynxResourceRequest, callback: LynxResourceCallback<ByteArray>) {
            fail(callback, "当前 OTA 页面没有声明 SSR 资源")
        }
    }
    val generic = object : LynxGenericResourceFetcher() {
        override fun fetchResource(request: LynxResourceRequest, callback: LynxResourceCallback<ByteArray>) {
            if (request.asyncMode != LynxResourceRequest.AsyncMode.EXACTLY_ASYNC) {
                readSynchronous(request, callback) { captured ->
                    verifiedBytes(captured.sidecars?.resource(request.url)
                        ?: throw IOException("当前代码 lease 未声明通用资源：${request.url}"))
                }
                return
            }
            enqueue(callback) { captured, deliver ->
                requestCounts.getOrPut(request.url) { AtomicInteger() }.incrementAndGet()
                io.execute { deliver(runCatching {
                    verifiedBytes(captured.sidecars?.resource(request.url)
                        ?: throw IOException("当前代码 lease 未声明通用资源：${request.url}"))
                }) }
            }
        }
        override fun fetchResourcePath(request: LynxResourceRequest, callback: LynxResourceCallback<String>) {
            val read: (Binding) -> String = { captured ->
                captured.sidecars?.resource(request.url)?.localFile()?.absolutePath
                    ?: throw IOException("当前代码 lease 没有通用资源文件：${request.url}")
            }
            if (request.asyncMode == LynxResourceRequest.AsyncMode.EXACTLY_ASYNC) {
                enqueue(callback) { captured, deliver -> io.execute { deliver(runCatching { read(captured) }) } }
            } else readSynchronous(request, callback, read)
        }
    }
    private fun <T : Any> readSynchronous(request: LynxResourceRequest, callback: LynxResourceCallback<T>,
        read: (Binding) -> T) {
        synchronousReads.incrementAndGet()
        val captured = binding
        try {
            requestCounts.getOrPut(request.url) { AtomicInteger() }.incrementAndGet()
            val result = runCatching { read(captured ?: throw IOException("引擎资源租约已关闭")) }
            if (captured == null || binding !== captured) fail(callback, "引擎资源租约已关闭")
            else result.fold({ callback.onResponse(LynxResourceResponse.onSuccess(it)) },
                { fail(callback, it.message ?: "本地附属资源读取失败") })
        } finally { synchronousReads.decrementAndGet() }
    }
    val media = object : LynxMediaResourceFetcher() {
        override fun isLocalResource(url: String): OptionalBool =
            if (binding?.sidecars?.resource(url)?.kind == OtaSidecarModels.AsyncKind.ASSET)
                OptionalBool.TRUE else OptionalBool.UNDEFINED
        override fun shouldRedirectUrl(request: LynxResourceRequest): String? {
            val entry = binding?.sidecars?.resource(request.url) ?: return null
            if (entry.kind != OtaSidecarModels.AsyncKind.ASSET) return null
            return Uri.fromFile(entry.localFile() ?: throw IOException("本地媒体资源不可用：${entry.requestKey}")).toString()
        }
    }
    private fun verifiedBytes(entry: OtaSidecarViewResources.ResolvedEntry): ByteArray = entry.readBytes().also {
        entry.expectedSize?.let { size -> require(it.size == size) { "引擎附属资源大小不符" } }
        entry.expectedSha256?.let { expected -> require(sha256(it) == expected) { "引擎附属资源 SHA256 不符" } }
    }
    private fun <T : Any> fail(callback: LynxResourceCallback<T>, message: String) {
        @Suppress("UNCHECKED_CAST")
        callback.onResponse(LynxResourceResponse.onFailed(IOException(message)) as LynxResourceResponse<T>)
    }
    private companion object {
        val main = Handler(Looper.getMainLooper())
        val io = Executors.newCachedThreadPool { task -> Thread(task, "lynx-engine-resource").apply { isDaemon = true } }
        fun sha256(bytes: ByteArray): String = "sha256:" + MessageDigest.getInstance("SHA-256")
            .digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
}
