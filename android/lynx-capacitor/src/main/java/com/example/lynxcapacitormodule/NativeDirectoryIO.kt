package com.example.lynxcapacitormodule

import java.io.File
import java.nio.file.Files
import org.json.JSONArray
import org.json.JSONObject

internal object NativeDirectoryIO {
    fun summary(file: File): JSONObject = JSONObject()
        .put("name", file.name)
        .put("type", if (file.isDirectory) "directory" else "file")
        .put("size", if (file.isFile) file.length() else 0L)
        // File 不暴露创建时间，沿用既有协议的 mtime 映射。
        .put("ctime", file.lastModified()).put("mtime", file.lastModified())
        .put("uri", file.toURI().toString())

    fun read(target: File): JSONArray {
        val budget = NativeJsonBudget()
        val entries = mutableListOf<JSONObject>()
        // 先按逐项预算限制存储，再排序；不先 listFiles 把整个巨大目录读入内存。
        Files.newDirectoryStream(target.toPath()).use { stream ->
            stream.forEach { path ->
                val item = summary(path.toFile())
                budget.reserve(1)
                budget.account(item)
                entries.add(item)
            }
        }
        return JSONArray(entries.sortedBy { it.getString("name") })
    }
}
