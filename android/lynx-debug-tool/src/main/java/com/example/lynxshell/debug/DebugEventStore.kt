package com.example.lynxshell.debug

import com.example.lynxshell.monitoring.MonitorEvent
import org.json.JSONArray
import org.json.JSONObject
import java.util.ArrayDeque

internal class DebugEventStore : LynxDebugSink {
    data class PageOption(val viewId: String, val label: String)
    private data class Event(val json: String, val viewId: String?, val bytes: Int)

    private val lock = Any()
    private val events = ArrayDeque<Event>()
    private val methods = ArrayDeque<LynxDebugMethodInvocation>()
    private val containers = LinkedHashMap<String, LynxDebugContainerSnapshot>()
    private var bytes = 0
    private var discarded = 0L

    override fun attach(snapshot: LynxDebugContainerSnapshot) {
        synchronized(lock) {
            containers[snapshot.viewId] = snapshot.copy(
                bundleUrl = DebugRedactor.bundleUrl(snapshot.bundleUrl),
                bundleMetadata = DebugRedactor.map(snapshot.bundleMetadata),
                globalProps = DebugRedactor.map(snapshot.globalProps),
            )
        }
    }

    override fun attachView(view: com.lynx.tasm.LynxView, viewId: String) {
        LynxConsoleSink.attach(view, viewId)
    }

    override fun updateVisibility(viewId: String, visibility: String) {
        synchronized(lock) {
            val current = containers[viewId] ?: return
            containers[viewId] = current.copy(visibility = visibility, updatedAtMs = System.currentTimeMillis())
        }
    }

    override fun updateGlobalProps(viewId: String, globalProps: Map<String, Any?>) {
        synchronized(lock) {
            val current = containers[viewId] ?: return
            containers[viewId] = current.copy(
                globalProps = DebugRedactor.map(globalProps),
                updatedAtMs = System.currentTimeMillis(),
            )
        }
    }

    override fun record(event: MonitorEvent) {
        val json = event.toJson()
        val item = Event(json, event.viewId, json.toByteArray(Charsets.UTF_8).size)
        synchronized(lock) {
            if (item.bytes > MAX_EVENT_BYTES) {
                discarded++
                return
            }
            while (events.size >= MAX_EVENTS || bytes + item.bytes > MAX_BYTES) {
                bytes -= events.removeFirst().bytes
                discarded++
            }
            events.addLast(item)
            bytes += item.bytes
        }
    }

    override fun recordMethod(invocation: LynxDebugMethodInvocation) {
        synchronized(lock) {
            if (methods.size >= MAX_METHODS) methods.removeFirst()
            methods.addLast(invocation.copy(
                params = invocation.params.take(16 * 1024),
                result = invocation.result?.take(16 * 1024),
            ))
        }
    }

    override fun detach(viewId: String) {
        synchronized(lock) { containers.remove(viewId) }
    }

    override fun detachView(view: com.lynx.tasm.LynxView, viewId: String) {
        LynxConsoleSink.detach(view)
    }

    fun clear(viewId: String? = null) {
        synchronized(lock) {
            if (viewId == null) {
                events.clear()
                methods.clear()
                bytes = 0
                discarded = 0
            } else {
                val kept = events.filter { it.viewId != viewId }
                events.clear()
                bytes = 0
                kept.forEach {
                    events.addLast(it)
                    bytes += it.bytes
                }
            }
        }
    }

    fun snapshotJson(): String = synchronized(lock) {
        val root = JSONObject()
            .put("schemaVersion", "1.0")
            .put("discarded", discarded)
        val containerArray = JSONArray()
        containers.values.forEach { container ->
            containerArray.put(
                JSONObject()
                    .put("viewId", container.viewId)
                    .put("containerKind", container.containerKind)
                    .put("visibility", container.visibility)
                    .put("routeKey", container.routeKey)
                    .put("title", container.title)
                    .put("bundleUrl", container.bundleUrl)
                    .put("bundleMetadata", JSONObject(container.bundleMetadata))
                    .put("globalProps", JSONObject(container.globalProps))
                    .put("updatedAtMs", container.updatedAtMs),
            )
        }
        root.put("containers", containerArray)
        val eventArray = JSONArray()
        events.forEach { event ->
            runCatching { JSONObject(event.json) }.onSuccess(eventArray::put)
        }
        root.put("events", eventArray)
        root.toString()
    }

    fun containersJson(): String = synchronized(lock) {
        containersJson(null)
    }

    fun containersJson(viewId: String?): String = synchronized(lock) {
        val array = JSONArray()
        containers.values.filter { viewId == null || it.viewId == viewId }.forEach { container ->
            array.put(
                JSONObject()
                    .put("containerId", container.viewId)
                    .put("templateUrl", container.bundleUrl)
                    .put("routeKey", container.routeKey)
                    .put("globalProps", JSONObject(container.globalProps))
                    .put("bundleMetadata", JSONObject(container.bundleMetadata)),
            )
        }
        array.toString(2)
    }

    fun pageOptions(): List<PageOption> = synchronized(lock) {
        containers.values.map { container ->
            PageOption(
                viewId = container.viewId,
                label = "${container.containerKind} · ${container.routeKey.ifBlank { container.title.ifBlank { container.viewId.take(8) } }}",
            )
        }
    }

    fun containers(viewId: String?): List<LynxDebugContainerSnapshot> = synchronized(lock) {
        containers.values.filter { viewId == null || it.viewId == viewId }
    }

    fun methodSnapshot(viewId: String?): List<LynxDebugMethodInvocation> = synchronized(lock) {
        methods.toList().filter { viewId == null || it.viewId == viewId }
    }

    fun methodsText(viewId: String? = null): String = synchronized(lock) {
        methods.toList().asReversed().filter { method -> viewId == null || method.viewId == viewId }.joinToString("\n\n") { method ->
            val status = when {
                method.endTimeMs == null -> "running"
                method.success == false -> "ERR"
                else -> "OK"
            }
            val duration = method.endTimeMs?.let { "${it - method.startTimeMs}ms" } ?: "running"
            buildString {
                append("[$status] ${method.name} · $duration")
                method.code?.let { append(" · code=$it") }
                append("\n» params\n${method.params.ifBlank { "(empty)" }}")
                append("\n« result\n${method.result ?: "(pending)"}")
            }
        }.ifBlank { "暂无 Native Method 调用记录" }
    }

    companion object {
        private const val MAX_EVENTS = 128
        private const val MAX_BYTES = 512 * 1024
        private const val MAX_EVENT_BYTES = 32 * 1024
        private const val MAX_METHODS = 300
    }
}
