package com.example.lynxshell.debug

import java.net.URI

internal object DebugRedactor {
    private val sensitiveKey = Regex("(?i).*(token|secret|password|passwd|authorization|cookie|accesskey|session).*" )

    fun map(value: Map<String, Any?>, depth: Int = 0): Map<String, Any?> {
        if (depth >= 4) return mapOf("<truncated>" to "max_depth")
        return value.entries
            .take(128)
            .associate { (key, item) ->
                key to if (sensitiveKey.matches(key)) "<redacted>" else any(item, depth + 1)
            }
    }

    fun bundleUrl(value: String): String = runCatching {
        val uri = URI(value)
        val host = uri.host ?: "local"
        val path = uri.path?.substringAfterLast('/').orEmpty().ifBlank { "bundle" }
        "${uri.scheme ?: "unknown"}://$host/$path"
    }.getOrElse { value.substringBefore('?').substringBefore('#').takeLast(256) }

    private fun any(value: Any?, depth: Int): Any? = when (value) {
        null, is String, is Number, is Boolean -> when {
            value is String && value.length > 4096 -> value.take(4096) + "<truncated>"
            else -> value
        }
        is Map<*, *> -> map(value.entries.associate { it.key.toString() to it.value }, depth)
        is Collection<*> -> value.take(128).map { any(it, depth) }
        else -> value.toString().take(1024)
    }
}
