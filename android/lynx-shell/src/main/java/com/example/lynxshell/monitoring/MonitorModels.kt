package com.example.lynxshell.monitoring

import org.json.JSONObject
import java.util.Collections

internal fun <T> frozen(values: Collection<T>): List<T> = Collections.unmodifiableList(ArrayList(values))
internal fun <K, V> frozen(values: Map<K, V>): Map<K, V> = Collections.unmodifiableMap(LinkedHashMap(values))

enum class ContainerKind(val wire: String) { PAGE("page"), TAB("tab"), EMBEDDED("embedded"), UNKNOWN("unknown") }
enum class Visibility(val wire: String) { VISIBLE("visible"), HIDDEN("hidden"), BACKGROUND("background"), UNKNOWN("unknown") }
enum class LoadKind(val wire: String) { INITIAL("initial"), RETRY("retry"), RELOAD("reload") }
enum class EventType(val wire: String) {
    LIFECYCLE("view.lifecycle"), LOAD("view.load"), PERFORMANCE("lynx.performance"),
    JS_ERROR("lynx.js_error"), RESOURCE("lynx.resource"), DIAGNOSTIC("monitor.diagnostic")
}

data class BundleIdentity internal constructor(
    val source: String,
    val lynxAppId: String?,
    val bundleName: String?,
    val releaseId: String? = null,
    val releaseSequence: String? = null,
    val sha256: String? = null,
    val identityStatus: String = "unavailable",
    val missingReason: String? = "bytes_not_resolved",
    val buildId: String? = null,
)

class EventQuality internal constructor(
    val association: String,
    val late: Boolean = false,
    missingFields: List<String> = emptyList(),
    invalidFields: List<String> = emptyList(),
    truncatedFields: List<String> = emptyList(),
) {
    val missingFields = frozen(missingFields.distinct().take(64))
    val invalidFields = frozen(invalidFields.distinct().take(64))
    val truncatedFields = frozen(truncatedFields.distinct().take(64))
}

data class Sampling(val owner: String, val rate: Double?)

sealed interface MonitorPayload { val eventType: EventType }
data class LifecyclePayload(val state: String, val durationMs: Double? = null) : MonitorPayload {
    override val eventType = EventType.LIFECYCLE
}
data class LoadPayload(val phase: String, val reasonCode: String? = null, val durationMs: Double? = null) : MonitorPayload {
    override val eventType = EventType.LOAD
}
class MetricValue internal constructor(val name: String, val value: Double, val origin: String, sourceFields: List<String>) {
    val unit = "ms"
    val sourceFields = frozen(sourceFields)
}
class PerformancePayload internal constructor(
    val entryType: String,
    val entryName: String,
    val identifier: String?,
    metrics: List<MetricValue>,
    timing: Map<String, Double>,
) : MonitorPayload {
    override val eventType = EventType.PERFORMANCE
    val metrics = frozen(metrics)
    val timing = frozen(timing)
}

sealed class ErrorPosition {
    data class LineColumn(val line: Int, val column: Int) : ErrorPosition()
    data class FunctionPc(val functionId: Int, val pc: Int) : ErrorPosition()
    object Unknown : ErrorPosition()
}
data class ErrorFrame internal constructor(
    val file: String?, val functionName: String?, val runtimeRelease: String?, val debugKey: String?,
    val position: ErrorPosition,
)
class JsErrorPayload internal constructor(
    val errorCode: String?, val subCode: String?, val level: String, val realm: String,
    val message: String, val rawStack: String?, frames: List<ErrorFrame>,
    val handled: String = "unknown", val phase: String,
) : MonitorPayload {
    override val eventType = EventType.JS_ERROR
    val frames = frozen(frames)
}
data class ResourcePayload(
    val resourceType: String, val outcome: String, val durationMs: Double? = null,
    val errorCode: String? = null, val resourceKey: String? = null,
) : MonitorPayload { override val eventType = EventType.RESOURCE }
data class DiagnosticPayload(val code: String, val count: Long, val detail: String? = null) : MonitorPayload {
    override val eventType = EventType.DIAGNOSTIC
}

class MonitorEvent internal constructor(
    val eventId: String, val processSessionId: String, val observedAtMs: Long,
    val runtimeVersion: String, val hostBuild: String, val viewId: String?, val nativeInstanceId: String?,
    val containerKind: ContainerKind, val loadId: String?, val loadKind: LoadKind?,
    val bundle: BundleIdentity?, val visibility: Visibility, val quality: EventQuality,
    val sampling: Sampling, val payload: MonitorPayload,
) {
    val schemaVersion = "1.0"
    val platform = "android"
    val eventType: EventType get() = payload.eventType

    /** 仅供 Provider 的分发线程或宿主诊断导出使用，不在 Lynx 回调中序列化。 */
    fun toJson(): String = JSONObject(wire()).toString()

    /** 按 JSON 转义后的 UTF-8 长度计预算，避免多字节文本突破队列上限。 */
    internal fun wireBytes(): Int = jsonBytes(wire())

    internal fun projected(value: Projection<out MonitorPayload>): MonitorEvent = MonitorEvent(
        eventId, processSessionId, observedAtMs, runtimeVersion, hostBuild, viewId, nativeInstanceId,
        containerKind, loadId, loadKind, bundle, visibility,
        EventQuality(quality.association, quality.late, quality.missingFields + value.missing,
            quality.invalidFields + value.invalid, quality.truncatedFields + value.truncated), sampling, value.payload,
    )

    private fun wire(): Map<String, Any?> = linkedMapOf(
        "schemaVersion" to schemaVersion, "eventId" to eventId, "processSessionId" to processSessionId,
        "observedAtMs" to observedAtMs, "platform" to platform, "eventType" to eventType.wire,
        "runtimeVersion" to runtimeVersion, "hostBuild" to hostBuild, "viewId" to viewId,
        "nativeInstanceId" to nativeInstanceId, "containerKind" to containerKind.wire,
        "loadId" to loadId, "loadKind" to loadKind?.wire, "bundle" to bundle?.let {
            linkedMapOf("source" to it.source, "lynxAppId" to it.lynxAppId, "bundleName" to it.bundleName,
                "releaseId" to it.releaseId, "releaseSequence" to it.releaseSequence, "sha256" to it.sha256,
                "identityStatus" to it.identityStatus, "missingReason" to it.missingReason, "buildId" to it.buildId)
        },
        "visibility" to visibility.wire,
        "quality" to linkedMapOf("association" to quality.association, "late" to quality.late,
            "missingFields" to quality.missingFields, "invalidFields" to quality.invalidFields,
            "truncatedFields" to quality.truncatedFields),
        "sampling" to linkedMapOf("owner" to sampling.owner, "rate" to sampling.rate),
        "payload" to payloadWire(),
    )

    private fun payloadWire(): Map<String, Any?> = when (val value = payload) {
        is LifecyclePayload -> linkedMapOf("state" to value.state, "durationMs" to value.durationMs)
        is LoadPayload -> linkedMapOf<String, Any?>("phase" to value.phase, "durationMs" to value.durationMs).apply {
            value.reasonCode?.let { put("reasonCode", it) }
        }
        is PerformancePayload -> linkedMapOf("entryType" to value.entryType, "entryName" to value.entryName,
            "identifier" to value.identifier, "timing" to value.timing,
            "metrics" to value.metrics.map { linkedMapOf("name" to it.name, "value" to it.value,
                "unit" to it.unit, "origin" to it.origin, "sourceFields" to it.sourceFields) })
        is JsErrorPayload -> linkedMapOf("errorCode" to value.errorCode, "subCode" to value.subCode,
            "level" to value.level, "realm" to value.realm, "message" to value.message,
            "rawStack" to value.rawStack, "handled" to value.handled, "phase" to value.phase,
            "frames" to value.frames.map { frame -> linkedMapOf<String, Any?>("file" to frame.file,
                "functionName" to frame.functionName, "runtimeRelease" to frame.runtimeRelease,
                "debugKey" to frame.debugKey).apply {
                when (val position = frame.position) {
                    is ErrorPosition.LineColumn -> { put("positionKind", "line_column"); put("line", position.line); put("column", position.column) }
                    is ErrorPosition.FunctionPc -> { put("positionKind", "function_pc"); put("functionId", position.functionId); put("pc", position.pc) }
                    ErrorPosition.Unknown -> put("positionKind", "unknown")
                }
            } })
        is ResourcePayload -> linkedMapOf("resourceType" to value.resourceType, "outcome" to value.outcome,
            "durationMs" to value.durationMs, "errorCode" to value.errorCode, "resourceKey" to value.resourceKey)
        is DiagnosticPayload -> linkedMapOf("code" to value.code, "count" to value.count, "detail" to value.detail)
    }
}

private fun jsonBytes(value: Any?): Int = when (value) {
    null -> 4
    is String -> {
        var bytes = 2
        var index = 0
        while (index < value.length) {
            val code = value.codePointAt(index)
            bytes += when {
                code == 34 || code == 92 || code == 47 -> 2
                code < 32 -> 6
                code < 128 -> 1
                code < 2048 -> 2
                code < 65536 -> 3
                else -> 4
            }
            index += Character.charCount(code)
        }
        bytes
    }
    is Map<*, *> -> 2 + value.entries.sumOf { jsonBytes(it.key) + 1 + jsonBytes(it.value) } + (value.size - 1).coerceAtLeast(0)
    is Collection<*> -> 2 + value.sumOf(::jsonBytes) + (value.size - 1).coerceAtLeast(0)
    else -> value.toString().length
}
