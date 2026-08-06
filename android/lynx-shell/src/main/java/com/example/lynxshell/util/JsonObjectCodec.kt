package com.example.lynxshell.util

import org.json.JSONArray
import org.json.JSONObject

/** 把 org.json 结构转换为 Lynx 可消费的 Java Map/List。 */
object JsonObjectCodec {
    fun requireObject(json: String, fieldName: String): JSONObject = try {
        JSONObject(json)
    } catch (error: Exception) {
        throw IllegalArgumentException("$fieldName 必须是合法 JSON Object", error)
    }

    fun toMap(json: String, fieldName: String): HashMap<String, Any> =
        objectToMap(requireObject(json, fieldName))

    fun objectToMap(source: JSONObject): HashMap<String, Any> {
        val result = HashMap<String, Any>()
        val keys = source.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            result[key] = convert(source.get(key))
        }
        return result
    }

    private fun arrayToList(source: JSONArray): List<Any> =
        (0 until source.length()).map { index -> convert(source.get(index)) }

    private fun convert(value: Any): Any = when (value) {
        is JSONObject -> objectToMap(value)
        is JSONArray -> arrayToList(value)
        // 保留 JSONObject.NULL，让 Lynx 能区分 null 与缺失字段。
        JSONObject.NULL -> JSONObject.NULL
        else -> value
    }
}
