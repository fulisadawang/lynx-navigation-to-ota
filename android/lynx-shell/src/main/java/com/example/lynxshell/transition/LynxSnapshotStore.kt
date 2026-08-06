package com.example.lynxshell.transition

import android.graphics.Bitmap
import android.os.SystemClock
import java.util.LinkedHashMap
import java.util.UUID

/**
 * 短生命周期 Bitmap LRU。
 *
 * token 只在当前进程有效；配置恢复或进程重启 miss 时调用方必须降级，不能重新使用旧 rect。
 */
object LynxSnapshotStore {
    // 单次多共享元素事务最多需要 1 张 Window + 8 张元素快照。原来的 4-entry
    // 上限会在 launch 前就把前四张 LRU 淘汰，导致“协议接受 8 个、运行只剩 3 个”。
    // 64MB 仍是硬上限；深栈超过预算时明确按 snapshot_unavailable 降级。
    private const val MAX_BYTES = 64L * 1024L * 1024L
    private const val MAX_ENTRIES = 64
    // open/shared 页面通常会停留数分钟；2 分钟会让正常返回无条件丢失反向 morph。
    // 生命周期释放与 64MB LRU 才是主回收手段，TTL 只负责兜底清理泄漏事务。
    private const val TTL_MS = 30L * 60L * 1_000L

    private data class Entry(
        val bitmap: Bitmap,
        val createdAtElapsedMs: Long,
        val byteCount: Long,
    )

    private val entries = LinkedHashMap<String, Entry>(8, 0.75f, true)
    private var totalBytes = 0L

    @Synchronized
    fun put(bitmap: Bitmap): String? {
        cleanupExpired()
        val size = bitmap.allocationByteCount.toLong()
        if (size <= 0L || size > MAX_BYTES) return null
        while (entries.isNotEmpty() && (entries.size >= MAX_ENTRIES || totalBytes + size > MAX_BYTES)) {
            removeEldest()
        }
        if (totalBytes + size > MAX_BYTES) return null
        val token = UUID.randomUUID().toString()
        entries[token] = Entry(bitmap, SystemClock.elapsedRealtime(), size)
        totalBytes += size
        return token
    }

    @Synchronized
    fun get(token: String?): Bitmap? {
        if (token.isNullOrBlank()) return null
        cleanupExpired()
        return entries[token]?.bitmap?.takeUnless(Bitmap::isRecycled)
    }

    @Synchronized
    fun remove(token: String?) {
        if (token.isNullOrBlank()) return
        entries.remove(token)?.let { totalBytes -= it.byteCount }
    }

    @Synchronized
    fun clear() {
        // ImageView/Animator 可能仍短暂持有 Bitmap，因此这里只释放 Store 引用，不主动 recycle。
        entries.clear()
        totalBytes = 0L
    }

    @Synchronized
    private fun cleanupExpired() {
        val cutoff = SystemClock.elapsedRealtime() - TTL_MS
        val iterator = entries.iterator()
        while (iterator.hasNext()) {
            val entry = iterator.next().value
            if (entry.createdAtElapsedMs < cutoff || entry.bitmap.isRecycled) {
                totalBytes -= entry.byteCount
                iterator.remove()
            }
        }
    }

    private fun removeEldest() {
        val first = entries.entries.firstOrNull() ?: return
        entries.remove(first.key)
        totalBytes -= first.value.byteCount
    }
}
