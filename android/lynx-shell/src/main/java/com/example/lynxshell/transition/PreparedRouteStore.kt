package com.example.lynxshell.transition

import android.content.Context
import android.os.SystemClock
import com.example.lynxshell.model.LynxPageRequest
import com.example.lynxshell.resource.ShellTemplateProvider
import java.util.LinkedHashMap
import java.util.UUID

data class PreparedRoute(
    val token: String,
    val routeKey: String,
    val sizeBytes: Int,
    val expiresAt: Long,
)

data class PreparedRouteClaim(
    val bytes: ByteArray? = null,
    val reason: String? = null,
)

/**
 * Bundle bytes 的进程内一次性 LRU。
 *
 * 这里只缓存通过 ShellTemplateProvider 安全校验的字节；不缓存 LynxView、Activity、
 * JS Runtime 或转场 Bitmap，也不把 bytes 写入 Intent / savedInstanceState。
 */
object PreparedRouteStore {
    private const val TTL_MS = 30_000L
    private const val MAX_ENTRIES = 4
    private const val MAX_TOTAL_BYTES = 32L * 1024L * 1024L

    private data class Entry(
        val routeKey: String,
        val bundleUrl: String,
        val bytes: ByteArray,
        val expiresAtElapsedMs: Long,
        val expiresAtWallMs: Long,
    )

    private val entries = LinkedHashMap<String, Entry>(8, 0.75f, true)
    private var totalBytes = 0L

    fun prepare(
        context: Context,
        request: LynxPageRequest,
        callback: (Result<PreparedRoute>) -> Unit,
    ) {
        ShellTemplateProvider.prefetch(
            context = context,
            uri = request.bundleUrl,
            allowHttpInDebug = request.allowHttpInDebug,
        ) { result ->
            callback(
                result.mapCatching { bytes ->
                    require(bytes.isNotEmpty()) { "预取 Bundle 内容为空" }
                    insert(request, bytes)
                },
            )
        }
    }

    @Synchronized
    fun consume(token: String, request: LynxPageRequest): PreparedRouteClaim {
        cleanupExpired()
        val entry = entries.remove(token)
            ?: return PreparedRouteClaim(reason = "prepared_route_expired")
        totalBytes -= entry.bytes.size
        if (
            entry.bundleUrl != request.bundleUrl ||
            entry.routeKey != request.resolvedRouteKey()
        ) {
            return PreparedRouteClaim(reason = "prepared_route_expired")
        }
        if (SystemClock.elapsedRealtime() >= entry.expiresAtElapsedMs) {
            return PreparedRouteClaim(reason = "prepared_route_expired")
        }
        return PreparedRouteClaim(bytes = entry.bytes)
    }

    @Synchronized
    fun cancel(token: String): Boolean {
        cleanupExpired()
        val removed = entries.remove(token) ?: return false
        totalBytes -= removed.bytes.size
        return true
    }

    @Synchronized
    fun clear() {
        entries.clear()
        totalBytes = 0L
    }

    @Synchronized
    private fun insert(request: LynxPageRequest, bytes: ByteArray): PreparedRoute {
        cleanupExpired()
        require(bytes.size.toLong() <= MAX_TOTAL_BYTES) { "预取 Bundle 超过 32MB 缓存上限" }
        while (
            entries.isNotEmpty() &&
            (entries.size >= MAX_ENTRIES || totalBytes + bytes.size > MAX_TOTAL_BYTES)
        ) {
            removeEldest()
        }
        require(totalBytes + bytes.size <= MAX_TOTAL_BYTES) { "预取缓存空间不足" }

        val token = UUID.randomUUID().toString()
        val expiresAtElapsed = SystemClock.elapsedRealtime() + TTL_MS
        val expiresAtWall = System.currentTimeMillis() + TTL_MS
        entries[token] = Entry(
            routeKey = request.resolvedRouteKey(),
            bundleUrl = request.bundleUrl,
            bytes = bytes,
            expiresAtElapsedMs = expiresAtElapsed,
            expiresAtWallMs = expiresAtWall,
        )
        totalBytes += bytes.size
        return PreparedRoute(
            token = token,
            routeKey = request.resolvedRouteKey(),
            sizeBytes = bytes.size,
            expiresAt = expiresAtWall,
        )
    }

    @Synchronized
    private fun cleanupExpired() {
        val now = SystemClock.elapsedRealtime()
        val iterator = entries.iterator()
        while (iterator.hasNext()) {
            val entry = iterator.next().value
            if (entry.expiresAtElapsedMs <= now) {
                totalBytes -= entry.bytes.size
                iterator.remove()
            }
        }
    }

    private fun removeEldest() {
        val first = entries.entries.firstOrNull() ?: return
        entries.remove(first.key)
        totalBytes -= first.value.bytes.size
    }
}
