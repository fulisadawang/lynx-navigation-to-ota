package com.example.lynxshell.transition

import android.graphics.Color
import kotlin.math.roundToInt

/**
 * Skyline wire color 的安全解析器。
 *
 * Android Color.parseColor 的 8 位 hex 是 #AARRGGBB，而页面协议采用常见的
 * #RRGGBBAA，因此必须在一个位置显式换位；同时兼容官方文档常见的 rgb()/rgba()。
 */
internal object LynxColorParser {
    private val hex6 = Regex("^#[0-9a-fA-F]{6}$")
    private val hex8 = Regex("^#[0-9a-fA-F]{8}$")
    private val functional = Regex(
        """^(rgba?)\(\s*([^,]+)\s*,\s*([^,]+)\s*,\s*([^,\)]+)(?:\s*,\s*([^,\)]+))?\s*\)$""",
        RegexOption.IGNORE_CASE,
    )
    private val namedColors = setOf(
        "black",
        "darkgray",
        "gray",
        "lightgray",
        "white",
        "red",
        "green",
        "blue",
        "yellow",
        "cyan",
        "magenta",
        "transparent",
    )

    fun isValid(value: String): Boolean = parseOrNull(value) != null

    fun parse(value: String?, fallback: Int): Int =
        value?.let(::parseOrNull) ?: fallback

    fun parseOrNull(raw: String): Int? {
        val value = raw.trim()
        if (hex6.matches(value)) return runCatching { Color.parseColor(value) }.getOrNull()
        if (hex8.matches(value)) {
            val rgb = value.substring(1, 7)
            val alpha = value.substring(7, 9)
            return runCatching { Color.parseColor("#$alpha$rgb") }.getOrNull()
        }
        if (value.lowercase() in namedColors) {
            return runCatching { Color.parseColor(value) }.getOrNull()
        }
        val match = functional.matchEntire(value) ?: return null
        val function = match.groupValues[1].lowercase()
        val red = parseChannel(match.groupValues[2]) ?: return null
        val green = parseChannel(match.groupValues[3]) ?: return null
        val blue = parseChannel(match.groupValues[4]) ?: return null
        val alphaValue = match.groupValues[5]
        if (function == "rgb" && alphaValue.isNotBlank()) return null
        if (function == "rgba" && alphaValue.isBlank()) return null
        val alpha = if (function == "rgba") {
            parseAlpha(alphaValue) ?: return null
        } else {
            255
        }
        return Color.argb(alpha, red, green, blue)
    }

    private fun parseChannel(raw: String): Int? {
        val value = raw.trim()
        return if (value.endsWith("%")) {
            val percent = value.dropLast(1).toFloatOrNull() ?: return null
            if (percent !in 0f..100f) return null
            (percent * 2.55f).roundToInt().coerceIn(0, 255)
        } else {
            val channel = value.toFloatOrNull() ?: return null
            if (channel !in 0f..255f) return null
            channel.roundToInt()
        }
    }

    private fun parseAlpha(raw: String): Int? {
        val value = raw.trim()
        return if (value.endsWith("%")) {
            val percent = value.dropLast(1).toFloatOrNull() ?: return null
            if (percent !in 0f..100f) return null
            (percent * 2.55f).roundToInt().coerceIn(0, 255)
        } else {
            val alpha = value.toFloatOrNull() ?: return null
            if (alpha !in 0f..1f) return null
            (alpha * 255f).roundToInt().coerceIn(0, 255)
        }
    }
}
