package com.example.lynxcapacitormodule

import org.json.JSONArray
import org.json.JSONObject

/** 构造每个集合元素前消费预算，不能等大数组已建立后才检查最终 envelope。 */
internal class NativeJsonBudget(private val limit: Long = NativePayloadBudget.RESULT_BYTES.toLong(), initialBytes: Long = 128) {
    var usedBytes: Long = initialBytes
        private set
    fun reserve(bytes: Long) {
        NativeCallContext.checkActive()
        NativePayloadBudget.check(usedBytes + bytes, limit, "RESULT_TOO_LARGE")
        usedBytes += bytes
    }
    fun array(): JSONArray { reserve(2); return JSONArray() }
    fun account(value: Any?) {
        when (value) {
            null, JSONObject.NULL -> reserve(4)
            is String -> reserve(quotedBytes(value))
            is Number -> reserve(JSONObject.numberToString(value).toByteArray(Charsets.UTF_8).size.toLong())
            is Boolean -> reserve(if (value) 4 else 5)
            is JSONArray -> {
                reserve(2)
                for (index in 0 until value.length()) { if (index > 0) reserve(1); account(value.opt(index)) }
            }
            is JSONObject -> {
                reserve(2)
                val keys = value.keys()
                var first = true
                while (keys.hasNext()) {
                    if (!first) reserve(1)
                    first = false
                    val key = keys.next()
                    account(key); reserve(1); account(value.opt(key))
                }
            }
            else -> throw IllegalArgumentException("不支持的原生 JSON 元素")
        }
    }
    private fun quotedBytes(text: String): Long {
        var bytes = 2L
        var index = 0
        while (index < text.length) {
            if (index % 1024 == 0) NativeCallContext.checkActive()
            val char = text[index]
            bytes += when {
                char == '\"' || char == '\\' || char == '/' -> 2
                char < ' ' || char.code in 0x80..0x9f || char.code in 0x2000..0x20ff -> 6
                char.code < 0x80 -> 1
                char.code < 0x800 -> 2
                char.isHighSurrogate() && index + 1 < text.length && text[index + 1].isLowSurrogate() -> { index++; 4 }
                else -> 3
            }
            NativePayloadBudget.check(usedBytes + bytes, limit, "RESULT_TOO_LARGE")
            index++
        }
        return bytes
    }
    fun append(array: JSONArray, value: Any?) {
        if (array.length() > 0) reserve(1)
        account(value)
        array.put(value)
    }
    fun appendAccountedArray(array: JSONArray, child: JSONArray) {
        if (array.length() > 0) reserve(1)
        array.put(child)
    }
    fun row(values: Sequence<Any?>): JSONArray {
        val result = array()
        values.forEach { append(result, it) }
        return result
    }
}
