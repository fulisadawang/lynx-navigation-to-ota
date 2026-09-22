package com.example.lynxshell.debug

import com.lynx.jsbridge.network.HttpRequest
import com.lynx.jsbridge.network.HttpResponse
import java.util.ArrayDeque

data class LynxDebugNetworkRequest(
    val id: String,
    val viewId: String?,
    val method: String,
    val url: String,
    val headers: Map<String, String>,
    val bodyBytes: Int,
    val startTimeMs: Long,
    val endTimeMs: Long? = null,
    val statusCode: Int? = null,
    val statusText: String? = null,
    val error: String? = null,
) {
    val curl: String
        get() = buildString {
            append("curl -X ").append(method).append(" '").append(DebugRedactor.bundleUrl(url)).append("'")
            headers.forEach { (key, value) -> append(" -H '").append(key).append(": ").append(value).append("'") }
            if (bodyBytes > 0) append(" --data-binary '<body ").append(bodyBytes).append(" bytes>'")
        }
}

internal object NetworkRequestStore {
    private const val MAX_RECORDS = 200
    private val lock = Any()
    private val records = ArrayDeque<LynxDebugNetworkRequest>()

    fun begin(request: HttpRequest, viewId: String? = null): String {
        val id = java.util.UUID.randomUUID().toString()
        val record = LynxDebugNetworkRequest(
            id = id,
            viewId = viewId,
            method = request.httpMethod.ifBlank { "GET" }.uppercase(),
            url = request.url,
            headers = request.httpHeaders?.toHashMap().orEmpty().mapValues { "<redacted>" },
            bodyBytes = request.httpBody?.size ?: 0,
            startTimeMs = System.currentTimeMillis(),
        )
        synchronized(lock) {
            if (records.size >= MAX_RECORDS) records.removeFirst()
            records.addLast(record)
        }
        return id
    }

    fun finish(id: String, response: HttpResponse? = null, error: String? = null) {
        synchronized(lock) {
            val current = records.firstOrNull { it.id == id } ?: return
            val updated = current.copy(
                endTimeMs = System.currentTimeMillis(),
                statusCode = response?.statusCode,
                statusText = response?.statusText,
                error = error,
            )
            val values = records.map { if (it.id == id) updated else it }
            records.clear()
            records.addAll(values)
        }
    }

    fun snapshot(viewId: String? = null): List<LynxDebugNetworkRequest> = synchronized(lock) {
        records.toList().filter { viewId == null || it.viewId == viewId }
    }

    fun clear() = synchronized(lock) { records.clear() }
}
