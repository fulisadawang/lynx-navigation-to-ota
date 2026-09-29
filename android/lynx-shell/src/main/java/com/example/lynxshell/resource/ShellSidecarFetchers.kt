package com.example.lynxshell.resource

import android.net.Uri
import com.lynx.tasm.LynxBooleanOption
import com.lynx.tasm.LynxViewBuilder
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
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** 每个 LynxView 只持有打开时的代码 lease 资源映射，不查询可变 current。 */
internal object ShellSidecarFetchers {
    private val io: ExecutorService = Executors.newCachedThreadPool { task ->
        Thread(task, "lynx-sidecar-local").apply { isDaemon = true }
    }

    private fun <T : Any> respond(callback: LynxResourceCallback<T>, result: Result<T>) {
        result.onSuccess { callback.onResponse(LynxResourceResponse.onSuccess(it)) }
        result.onFailure { error ->
            @Suppress("UNCHECKED_CAST")
            callback.onResponse(LynxResourceResponse.onFailed(error) as LynxResourceResponse<T>)
        }
    }

    fun install(builder: LynxViewBuilder, resources: OtaSidecarViewResources?,
        mainUrl: String, mainProvider: ShellTemplateProvider) {
        if (resources == null) return
        // Lynx 4.1 只有开启此门禁，才会把 Template Fetcher 接入 lazy Bundle 加载器。
        if (resources.entries.isNotEmpty()) builder.setEnableGenericResourceFetcher(LynxBooleanOption.TRUE)
        builder.setTemplateResourceFetcher(object : LynxTemplateResourceFetcher() {
            override fun fetchTemplate(request: LynxResourceRequest,
                callback: LynxResourceCallback<TemplateProviderResult>) {
                val action = {
                    val result = runCatching {
                        val entry = resources.resource(request.url)
                        if (entry?.kind != OtaSidecarModels.AsyncKind.BUNDLE) {
                            throw IOException("当前代码 lease 未声明动态组件：${request.url}")
                        }
                        TemplateProviderResult.fromBinary(entry.readBytes())
                    }
                    respond(callback, result)
                }
                if (request.url == mainUrl) {
                    mainProvider.loadTemplate(request.url, object : AbsTemplateProvider.Callback {
                        override fun onSuccess(data: ByteArray) {
                            callback.onResponse(LynxResourceResponse.onSuccess(TemplateProviderResult.fromBinary(data)))
                        }
                        override fun onFailed(message: String) {
                            respond(callback, Result.failure(IOException(message)))
                        }
                    })
                } else if (request.asyncMode == LynxResourceRequest.AsyncMode.EXACTLY_ASYNC) {
                    io.execute(action)
                } else {
                    action()
                }
            }

            override fun fetchSSRData(request: LynxResourceRequest, callback: LynxResourceCallback<ByteArray>) {
                respond(callback, Result.failure(IOException("当前 OTA 页面没有声明 SSR 资源")))
            }
        })

        val mediaExtensions = setOf("png", "jpg", "jpeg", "webp", "gif", "svg", "avif", "mp4", "webm")
        fun isMedia(entry: OtaSidecarViewResources.ResolvedEntry): Boolean =
            entry.requestKey.substringAfterLast('.', "").lowercase() in mediaExtensions
        if (resources.entries.any { it.kind == OtaSidecarModels.AsyncKind.SCRIPT ||
                it.kind == OtaSidecarModels.AsyncKind.STYLE ||
                (it.kind == OtaSidecarModels.AsyncKind.ASSET && !isMedia(it)) }) {
            builder.setGenericResourceFetcher(object : LynxGenericResourceFetcher() {
                override fun fetchResource(request: LynxResourceRequest, callback: LynxResourceCallback<ByteArray>) {
                    io.execute {
                        val result = runCatching {
                            val entry = resources.resource(request.url)
                                ?: throw IOException("当前代码 lease 未声明通用资源：${request.url}")
                            entry.readBytes()
                        }
                        respond(callback, result)
                    }
                }

                override fun fetchResourcePath(request: LynxResourceRequest, callback: LynxResourceCallback<String>) {
                    val result = runCatching {
                        resources.resource(request.url)?.localFile()?.absolutePath
                            ?: throw IOException("当前代码 lease 未声明通用资源：${request.url}")
                    }
                    respond(callback, result)
                }
            })
        }

        if (resources.entries.any { it.kind == OtaSidecarModels.AsyncKind.ASSET && isMedia(it) }) {
            builder.setMediaResourceFetcher(object : LynxMediaResourceFetcher() {
                override fun isLocalResource(url: String): OptionalBool =
                    if (resources.resource(url)?.let { it.kind == OtaSidecarModels.AsyncKind.ASSET && isMedia(it) } == true)
                        OptionalBool.TRUE else OptionalBool.UNDEFINED

                override fun shouldRedirectUrl(request: LynxResourceRequest): String? {
                    val entry = resources.resource(request.url)
                    if (entry?.kind != OtaSidecarModels.AsyncKind.ASSET || !isMedia(entry)) return null
                    val file = entry.localFile()
                        ?: throw IOException("本地媒体资源不可用：${entry.requestKey}")
                    return Uri.fromFile(file).toString()
                }
            })
        }
    }
}
