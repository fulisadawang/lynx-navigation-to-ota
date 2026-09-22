package com.example.lynxshell.debug

import android.util.Log

data class ConsoleLog(
    val type: String,
    val level: Int,
    val message: String,
    val tag: String = "",
    val viewId: String? = null,
    val timestamp: Long = System.currentTimeMillis(),
) {
    companion object {
        fun fromPlain(level: Int, tag: String?, message: String, viewId: String? = null): ConsoleLog =
            ConsoleLog(
                type = when (level) {
                    Log.ERROR -> "error"
                    Log.WARN -> "warn"
                    Log.INFO -> "info"
                    Log.DEBUG -> "debug"
                    else -> "log"
                },
                level = level,
                tag = tag.orEmpty(),
                message = message.take(16 * 1024),
                viewId = viewId,
            )
    }
}
