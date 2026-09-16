package com.example.lynxshell.monitoring

import com.lynx.tasm.LynxError
import com.lynx.tasm.performance.performanceobserver.LazyBundleEntry
import com.lynx.tasm.performance.performanceobserver.LoadBundleEntry
import com.lynx.tasm.performance.performanceobserver.PerformanceEntry
import com.lynx.tasm.performance.performanceobserver.PipelineEntry
import com.lynx.tasm.performance.performanceobserver.ReloadBundleEntry
import org.json.JSONObject

/** 默认隐藏 URL 查询及常见凭据字段；宿主可补充必须移除的业务文本，不影响脚本调试 key。 */
class MonitorTextPolicy(redactedLiterals: Collection<String> = emptyList()) {
    private val literals = frozen(redactedLiterals.filter(String::isNotEmpty))
    override fun equals(other: Any?): Boolean = other is MonitorTextPolicy && literals == other.literals
    override fun hashCode(): Int = literals.hashCode()
    internal fun sanitize(value: String): String {
        var result = URL.replace(value) { match -> match.value.substringBefore('?').substringBefore('#') }
        result = SECRET.replace(result) { "${it.groupValues[1]}=[redacted]" }
        result = BEARER.replace(result, "Bearer [redacted]")
        literals.forEach { result = result.replace(it, "[redacted]") }
        return result
    }
    private companion object {
        val URL = Regex("https?://[^\\s<>\"')]+")
        val SECRET = Regex("(?i)\\b(token|cookie|password|authorization|access_token|refresh_token)\\s*[:=]\\s*[^\\s,;]+")
        val BEARER = Regex("(?i)Bearer\\s+[A-Za-z0-9._~+/-]+")
    }
}

internal fun utf8Prefix(value: String, maxBytes: Int): String {
    var bytes = 0
    var end = 0
    while (end < value.length) {
        val cp = value.codePointAt(end)
        val length = when { cp < 128 -> 1; cp < 2048 -> 2; cp < 65536 -> 3; else -> 4 }
        if (bytes + length > maxBytes) break
        bytes += length
        end += Character.charCount(cp)
    }
    return value.substring(0, end)
}

internal fun utf8Bytes(value: String, stopAfter: Int = MAX_QUEUE_BYTES): Int {
    var bytes = 0
    var index = 0
    while (index < value.length && bytes <= stopAfter) {
        val cp = value.codePointAt(index)
        bytes += when { cp < 128 -> 1; cp < 2048 -> 2; cp < 65536 -> 3; else -> 4 }
        index += Character.charCount(cp)
    }
    return bytes
}

internal data class Projection<T>(val payload: T, val missing: List<String> = emptyList(), val invalid: List<String> = emptyList(), val truncated: List<String> = emptyList())
internal data class CapturedJsError(
    val errorCode: String, val subCode: String, val level: String, val realm: String,
    val summary: String, val encoded: String, val truncatedInput: Boolean,
)

enum class ScriptPositionFormat { LINE_COLUMN, FUNCTION_PC }

/** 仅登记同次构建清单已证实的脚本格式；debugKey 不得用 OTA SHA 或文件名替代。 */
class ScriptPositionFormats(byDebugKey: Map<String, ScriptPositionFormat> = emptyMap()) {
    private val values = frozen(byDebugKey)
    internal fun find(debugKey: String?): ScriptPositionFormat? = debugKey?.let(values::get)
    override fun equals(other: Any?): Boolean = other is ScriptPositionFormats && values == other.values
    override fun hashCode(): Int = values.hashCode()
}

internal object MonitorProjection {
    private val stages = linkedMapOf(
        "mts_render_ms" to ("mtsRenderStart" to "mtsRenderEnd"),
        "style_resolve_ms" to ("resolveStart" to "resolveEnd"),
        "layout_ms" to ("layoutStart" to "layoutEnd"),
        "paint_ui_ops_ms" to ("paintingUiOperationExecuteStart" to "paintingUiOperationExecuteEnd"),
        "pipeline_ms" to ("pipelineStart" to "pipelineEnd"),
    )

    fun performance(entry: PerformanceEntry): Projection<PerformancePayload>? {
        if (entry !is PipelineEntry && entry !is LazyBundleEntry) return null
        val raw = entry.toHashMap()
        val missing = mutableListOf<String>()
        val invalid = mutableListOf<String>()
        val timing = linkedMapOf<String, Double>()
        val metrics = mutableListOf<MetricValue>()
        fun number(key: String): Double? {
            if (!raw.containsKey(key)) { missing.add(key); return null }
            val value = (raw[key] as? Number)?.toDouble()
            if (value == null || !value.isFinite() || value < 0) { invalid.add(key); return null }
            timing[key] = value
            return value
        }
        fun difference(name: String, start: String, end: String) {
            val from = number(start)
            val to = number(end)
            if (from != null && to != null) {
                if (to < from) invalid.add("$end<$start")
                else metrics.add(MetricValue(name, to - from, "sdk_timestamp_difference", listOf(start, end)))
            }
        }
        if (entry is PipelineEntry) {
            stages.forEach { (name, pair) -> difference(name, pair.first, pair.second) }
            number("paintEnd")
            // ActualFMP 保留原始 SDK 时间信息，不新增未经契约定义的指标名。
            listOf("actualFmp", "lynxActualFmp", "totalActualFmp").forEach { key ->
                val metric = raw[key] as? Map<*, *> ?: return@forEach
                listOf("duration", "startTimestamp", "endTimestamp").forEach { field ->
                    val value = (metric[field] as? Number)?.toDouble()
                    if (value != null && value.isFinite() && value >= 0) timing["$key.$field"] = value
                }
            }
        }
        if (entry is LoadBundleEntry || entry is ReloadBundleEntry) {
            listOf("lynxFcp" to "lynx_fcp_ms", "fcp" to "prepare_to_fcp_ms", "totalFcp" to "open_to_fcp_ms").forEach { (key, name) ->
                val metric = raw[key] as? Map<*, *>
                if (metric == null) { missing.add("$key.duration"); return@forEach }
                val duration = (metric["duration"] as? Number)?.toDouble()
                if (duration == null || !duration.isFinite() || duration < 0) invalid.add("$key.duration")
                else metrics.add(MetricValue(name, duration, "sdk_duration", listOf("$key.duration")))
            }
            if (entry is LoadBundleEntry) {
                difference("parse_ms", "parseStart", "parseEnd")
                difference("bts_load_ms", "loadBackgroundStart", "loadBackgroundEnd")
                listOf("loadBundleStart", "loadBundleEnd").forEach(::number)
            } else {
                // reloadBackground 的起点不是初次脚本加载，首版只保留原始字段。
                listOf("reloadBundleStart", "reloadBundleEnd", "reloadBackgroundStart", "reloadBackgroundEnd").forEach(::number)
            }
        }
        if (entry is LazyBundleEntry) listOf("requireStart", "requireEnd", "decodeStart", "decodeEnd").forEach(::number)
        val type = entry.entryType
        if (type !in setOf("init", "metric", "pipeline", "resource") || entry.name.isNullOrBlank()) return null
        return Projection(PerformancePayload(type, utf8Prefix(entry.name, 128),
            (entry as? PipelineEntry)?.identifier?.takeIf(String::isNotBlank)?.let { utf8Prefix(it, 512) }, metrics, timing), missing, invalid)
    }

    /** SDK 没有 callStack getter；只复制其有界字符串与标量，JSON/脱敏/拆帧留在监控线程。 */
    fun captureError(error: LynxError): CapturedJsError? {
        if (!error.isJSError && !error.isLepusError && error.type != LynxError.JS_ERROR) return null
        val raw = error.msg
        val summary = error.summaryMessage
        val summaryCopy = utf8Prefix(summary, 4096)
        val realm = when { error.isLepusError -> "main_thread"; error.isJSError || error.type == LynxError.JS_ERROR -> "background"; else -> "unknown" }
        val level = when (error.level) { "fatal" -> "fatal"; "error" -> "error"; "warn", "warning" -> "warning"; else -> "unknown" }
        return CapturedJsError(error.errorCode.toString(), error.subCode.toString(), level, realm,
            summaryCopy, raw, summaryCopy.length < summary.length)
    }

    fun error(error: CapturedJsError, policy: MonitorTextPolicy, phase: String, formats: ScriptPositionFormats): Projection<JsErrorPayload> {
        val truncated = mutableListOf<String>()
        val missing = mutableListOf<String>()
        val invalid = mutableListOf<String>()
        val encoded = error.encoded
        val json = if (encoded.startsWith("{")) {
            try { JSONObject(encoded) } catch (_: Exception) { invalid.add("sdk_error_json"); null }
        } else null
        if (error.truncatedInput) truncated.add("sdk_error_input")
        val summary = error.summary.ifBlank { json?.optString("error").orEmpty() }
        val message = policy.sanitize(summary).let { value -> utf8Prefix(value, 4096).also { if (it.length < value.length) truncated.add("message") } }
        val stack = json?.optString("error_stack")?.takeIf(String::isNotBlank)
            ?: summary.takeIf { it.lineSequence().any { line -> line.trimStart().startsWith("at ") } }
        val rawStack = stack?.let { policy.sanitize(it) }?.let { value ->
            utf8Prefix(value, 16 * 1024).also { if (it.length < value.length) truncated.add("rawStack") }
        }
        if (rawStack == null) missing.add("rawStack")
        val release = json?.optString("release")?.takeIf { it.startsWith("debugmetadata:") }
        val frames = parseFrames(rawStack.orEmpty(), release, truncated, formats)
        if (frames.isEmpty()) missing.add("frames")
        if (frames.any { it.debugKey == null }) missing.add("frames.debugKey")
        if (frames.any { it.position == ErrorPosition.Unknown }) missing.add("frames.positionKind")
        return Projection(JsErrorPayload(error.errorCode, error.subCode, error.level, error.realm,
            message, rawStack, frames, phase = phase), missing, invalid, truncated)
    }

    internal fun parseFrames(stack: String, release: String?, truncated: MutableList<String>,
        formats: ScriptPositionFormats = ScriptPositionFormats()): List<ErrorFrame> {
        val result = ArrayList<ErrorFrame>()
        var frameBytes = 0
        for (line in stack.lineSequence()) {
            val position = LOCATION.find(line)
            val explicitPc = FUNCTION_PC.find(line)
            if (position == null && explicitPc == null) continue
            if (result.size == 64 || frameBytes + line.toByteArray(Charsets.UTF_8).size > 6 * 1024) { truncated.add("frames"); break }
            frameBytes += line.toByteArray(Charsets.UTF_8).size
            val runtimeRelease = DEBUG_KEY.find(line)?.value ?: release
            val format = formats.find(runtimeRelease?.removePrefix("debugmetadata:"))
            val first = position?.groupValues?.get(2)?.toIntOrNull()
            val second = position?.groupValues?.get(3)?.toIntOrNull()
            val kind = when {
                explicitPc != null -> {
                    val function = explicitPc.groupValues[1].toIntOrNull()
                    val pc = explicitPc.groupValues[2].toIntOrNull()
                    if (function != null && pc != null) ErrorPosition.FunctionPc(function, pc) else ErrorPosition.Unknown
                }
                // 两个 realm 都可能遇到字节码；只使用本次构建登记的格式，不从文件名或 realm 猜测。
                format == ScriptPositionFormat.FUNCTION_PC && first != null && second != null -> ErrorPosition.FunctionPc(first, second)
                format == ScriptPositionFormat.LINE_COLUMN && first != null && first > 0 && second != null -> ErrorPosition.LineColumn(first, second)
                else -> ErrorPosition.Unknown
            }
            val function = line.trim().removePrefix("at ").substringBefore(" (").takeIf { " (" in line }?.let { utf8Prefix(it, 256) }
            result.add(ErrorFrame(position?.groupValues?.get(1)?.let { utf8Prefix(it, 1024) }, function,
                runtimeRelease?.let { utf8Prefix(it, 1024) }, runtimeRelease?.removePrefix("debugmetadata:")?.let { utf8Prefix(it, 1024) }, kind))
        }
        return result
    }

    private val LOCATION = Regex("(?:\\(|@|\\s)((?:file://|https?://|/)?[^\\s()]+?):([0-9]+):([0-9]+)\\)?")
    private val FUNCTION_PC = Regex("function[_ ]?id\\s*[:=]\\s*([0-9]+).*?pc(?:_index)?\\s*[:=]\\s*([0-9]+)", RegexOption.IGNORE_CASE)
    private val DEBUG_KEY = Regex("debugmetadata:[A-Za-z0-9._/-]+")
}
