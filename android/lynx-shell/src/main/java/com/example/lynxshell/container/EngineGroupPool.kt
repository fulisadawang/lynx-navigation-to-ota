package com.example.lynxshell.container

/** 每个 slot 只租给一个活体 View；预算中的字节是模板成本，不是原生引擎内存。 */
internal class EngineGroupPool<K, T>(
    private val maxIdleCount: Int,
    private val maxIdleBytes: Long,
    private val idleTtlMs: Long,
    private val now: () -> Long,
    private val release: (T) -> Unit,
) {
    private class Entry<K, T>(val key: K, val value: T, val bytes: Long) {
        var active = true
        var retired = false
        var idleSince = 0L
    }
    private val entries = mutableListOf<Entry<K, T>>()
    data class Snapshot(val activeCount: Int, val idleCount: Int, val idleEncodedBytes: Long)
    val snapshot: Snapshot get() = Snapshot(entries.count { it.active }, entries.count { !it.active },
        entries.filter { !it.active }.sumOf { it.bytes })

    class Lease<T> internal constructor(val value: T, val reused: Boolean,
        private val returnEntry: (Boolean) -> Unit) {
        private var closed = false
        fun close(reusable: Boolean) {
            if (closed) return
            closed = true
            returnEntry(reusable)
        }
    }

    fun acquire(key: K, encodedBytes: Long, create: () -> T): Lease<T> {
        evictExpired()
        val idle = entries.lastOrNull { !it.active && !it.retired && it.key == key }
        val entry = idle ?: Entry(key, create(), encodedBytes).also(entries::add)
        entry.active = true
        return Lease(entry.value, idle != null) { reusable ->
            entry.active = false
            if (!reusable || entry.retired || entry.bytes > maxIdleBytes || maxIdleCount == 0) {
                remove(entry)
            } else {
                entry.idleSince = now()
                entries.remove(entry)
                entries.add(entry)
                while (snapshot.idleCount > maxIdleCount || snapshot.idleEncodedBytes > maxIdleBytes) {
                    remove(entries.first { !it.active })
                }
            }
        }
    }

    fun invalidate(predicate: (K) -> Boolean) {
        entries.toList().filter { predicate(it.key) }.forEach {
            if (it.active) it.retired = true else remove(it)
        }
    }
    fun clear() = invalidate { true }
    fun evictExpired() {
        val time = now()
        entries.toList().filter { !it.active && time - it.idleSince >= idleTtlMs }.forEach(::remove)
    }
    private fun remove(entry: Entry<K, T>) {
        if (entries.remove(entry)) release(entry.value)
    }
}
