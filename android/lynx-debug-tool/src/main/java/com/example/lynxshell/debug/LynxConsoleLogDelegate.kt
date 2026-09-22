package com.example.lynxshell.debug

import android.util.Log
import com.lynx.tasm.base.AbsLogDelegate
import com.lynx.tasm.base.IComplicatedLogDelegate
import com.lynx.tasm.base.LLog
import com.lynx.tasm.base.LogSource
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 参考 Sparkling 的 Android fallback 路径：从 Lynx LLog 中只接收 JS/JS_EXT 来源。
 * 不把宿主所有 Android Log 都混入 Console 面板。
 */
internal object LynxConsoleLogDelegate : AbsLogDelegate(), IComplicatedLogDelegate {
    private val installed = AtomicBoolean(false)
    private var pendingSource: LogSource? = null
    private var pendingRuntimeId: Long? = null

    init { mMinimumLoggingLevel = Log.VERBOSE }

    fun installOnce() {
        if (!installed.compareAndSet(false, true)) return
        LLog.setMinimumLoggingLevel(Log.VERBOSE)
        runCatching { LLog.setJSLogsFromExternalChannels(true) }
        runCatching { LLog.setDebugLoggingDelegate(this) }
            .onFailure { runCatching { LLog.addLoggingDelegate(this) } }
    }

    override fun getShouldFormatMessage(): Boolean = false
    override fun isLoggable(level: Int): Boolean = true
    override fun isLoggable(source: LogSource?, level: Int): Boolean = true

    override fun isComplicatedLogLoggable(level: Int, source: LogSource?, runtimeId: Long?): Boolean {
        pendingSource = source
        pendingRuntimeId = runtimeId
        return true
    }

    override fun v(tag: String?, msg: String?) = record(Log.VERBOSE, tag, msg)
    override fun d(tag: String?, msg: String?) = record(Log.DEBUG, tag, msg)
    override fun i(tag: String?, msg: String?) = record(Log.INFO, tag, msg)
    override fun w(tag: String?, msg: String?) = record(Log.WARN, tag, msg)
    override fun e(tag: String?, msg: String?) = record(Log.ERROR, tag, msg)
    override fun log(priority: Int, tag: String?, msg: String?) = record(priority, tag, msg)

    private fun record(priority: Int, tag: String?, msg: String?) {
        if (msg.isNullOrBlank()) return
        val source = pendingSource
        val runtimeId = pendingRuntimeId
        pendingSource = null
        pendingRuntimeId = null
        val isJs = source == LogSource.JS || source == LogSource.JS_EXT ||
            (source == null && runtimeId == null && msg.contains("console.cc"))
        if (!isJs) return
        ConsoleLogStore.add(
            ConsoleLog.fromPlain(
                level = priority,
                tag = tag ?: "console",
                message = msg.substringAfter(")]", msg).replace('\n', ' ').trim(),
                viewId = LynxDebugBridge.viewIdForRuntime(runtimeId),
            ),
        )
    }
}
