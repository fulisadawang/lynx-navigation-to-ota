package com.example.lynxshell.debug

import com.example.lynxshell.model.LynxPageRequest
import com.example.lynxshell.monitoring.MonitorEvent
import com.lynx.tasm.LynxView
import com.lynx.tasm.behavior.LynxContext
import java.util.Collections
import java.util.UUID
import java.util.WeakHashMap

/**
 * Shell 与可选 Debug Module 之间的轻量 SPI。
 *
 * 此实现只属于 Debug 源码集；生产源码生成任务会移除全部诊断调用。
 * Debug Module 只接收不可变的标量/Map 快照，不通过这个接口操作 Router、View 或 OTA。
 */
data class LynxDebugContainerSnapshot(
    val viewId: String,
    val containerKind: String,
    val visibility: String,
    val routeKey: String,
    val title: String,
    val bundleUrl: String,
    val bundleMetadata: Map<String, Any?>,
    val globalProps: Map<String, Any?>,
    val updatedAtMs: Long,
)

data class LynxDebugMethodInvocation(
    val id: String,
    val name: String,
    val viewId: String? = null,
    val platform: String = "android",
    val params: String = "",
    val result: String? = null,
    val code: Int? = null,
    val success: Boolean? = null,
    val startTimeMs: Long,
    val endTimeMs: Long? = null,
)

interface LynxDebugSink {
    fun attach(snapshot: LynxDebugContainerSnapshot)
    fun attachView(view: LynxView, viewId: String) = Unit
    fun updateVisibility(viewId: String, visibility: String)
    fun updateGlobalProps(viewId: String, globalProps: Map<String, Any?>)
    fun record(event: MonitorEvent)
    fun recordMethod(invocation: LynxDebugMethodInvocation) = Unit
    fun detachView(view: LynxView, viewId: String) = Unit
    fun detach(viewId: String)
}

object LynxDebugBridge {
    private val lock = Any()
    private val viewIds = Collections.synchronizedMap(WeakHashMap<LynxView, String>())
    private val runtimeIds = java.util.concurrent.ConcurrentHashMap<Long, String>()
    @Volatile private var sink: LynxDebugSink? = null

    fun install(value: LynxDebugSink) {
        synchronized(lock) { sink = value }
    }

    fun uninstall(value: LynxDebugSink) {
        synchronized(lock) {
            if (sink === value) sink = null
        }
    }

    fun attach(
        view: LynxView,
        viewId: String?,
        containerKind: String,
        request: LynxPageRequest,
        bundleMetadata: Map<String, Any>?,
        globalProps: Map<String, Any>,
    ): String {
        val activeSink = sink ?: return viewId.orEmpty()
        val id = viewId?.takeIf(String::isNotBlank) ?: UUID.randomUUID().toString()
        viewIds[view] = id
        view.lynxContext?.runtimeId?.let { runtimeIds[it] = id }
        activeSink.attach(
            LynxDebugContainerSnapshot(
                viewId = id,
                containerKind = containerKind,
                visibility = "unknown",
                routeKey = request.resolvedRouteKey(),
                title = request.title,
                bundleUrl = request.bundleUrl,
                bundleMetadata = bundleMetadata.orEmpty(),
                globalProps = globalProps,
                updatedAtMs = System.currentTimeMillis(),
            ),
        )
        activeSink.attachView(view, id)
        return id
    }

    fun updateVisibility(view: LynxView?, visibility: String) {
        val id = view?.let { viewIds[it] } ?: return
        sink?.updateVisibility(id, visibility)
    }

    fun updateGlobalProps(view: LynxView?, globalProps: Map<String, Any?>) {
        val id = view?.let { viewIds[it] } ?: return
        sink?.updateGlobalProps(id, globalProps)
    }

    fun record(event: MonitorEvent) {
        sink?.record(event)
    }

    fun viewIdForRuntime(runtimeId: Long?): String? {
        runtimeId?.let { runtimeIds[it]?.let { id -> return id } }
        synchronized(viewIds) {
            return if (viewIds.size == 1) viewIds.values.firstOrNull() else null
        }
    }

    data class MethodToken(
        val id: String,
        val name: String,
        val startTimeMs: Long,
        val viewId: String?,
        val params: String,
    )

    fun beginMethod(name: String, params: String = "", context: Any? = null): MethodToken? {
        if (sink == null) return null
        val viewId = (context as? LynxContext)?.lynxView?.let { viewIds[it] }
        return MethodToken(
            id = UUID.randomUUID().toString(),
            name = name,
            startTimeMs = System.currentTimeMillis(),
            viewId = viewId,
            params = params.take(16 * 1024),
        )
    }

    fun finishMethod(token: MethodToken?, code: Int?, success: Boolean?, result: String? = null) {
        if (token == null) return
        sink?.recordMethod(
            LynxDebugMethodInvocation(
                id = token.id,
                name = token.name,
                viewId = token.viewId,
                params = token.params,
                result = result?.take(16 * 1024),
                code = code,
                success = success,
                startTimeMs = token.startTimeMs,
                endTimeMs = System.currentTimeMillis(),
            ),
        )
    }

    fun detach(view: LynxView?) {
        val id = view ?: return
        val viewId = viewIds.remove(id) ?: return
        id.lynxContext?.runtimeId?.let(runtimeIds::remove)
        sink?.detachView(id, viewId)
        sink?.detach(viewId)
    }
}
