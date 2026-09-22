package com.example.lynxshell.debug

import android.os.Handler
import android.os.Looper
import java.util.ArrayDeque
import java.util.concurrent.CopyOnWriteArrayList

internal object ConsoleLogStore {
    interface Listener { fun onChanged() }

    private const val CAPACITY = 300
    private val lock = Any()
    private val logs = ArrayDeque<ConsoleLog>()
    private val listeners = CopyOnWriteArrayList<Listener>()
    private val main = Handler(Looper.getMainLooper())

    fun add(log: ConsoleLog) {
        synchronized(lock) {
            val previous = logs.lastOrNull()
            if (previous != null && previous.type == log.type && previous.tag == log.tag &&
                previous.message == log.message && log.timestamp - previous.timestamp < 500
            ) return
            if (logs.size >= CAPACITY) logs.removeFirst()
            logs.addLast(log)
        }
        notifyChanged()
    }

    fun snapshot(viewId: String? = null): List<ConsoleLog> = synchronized(lock) {
        logs.filter { viewId == null || it.viewId == viewId }
    }

    fun clear() {
        synchronized(lock) { logs.clear() }
        notifyChanged()
    }

    fun addListener(listener: Listener) { listeners.addIfAbsent(listener) }
    fun removeListener(listener: Listener) { listeners.remove(listener) }

    private fun notifyChanged() {
        if (listeners.isEmpty()) return
        val dispatch = { listeners.forEach { runCatching { it.onChanged() } } }
        if (Looper.myLooper() == Looper.getMainLooper()) dispatch() else main.post(dispatch)
    }
}
