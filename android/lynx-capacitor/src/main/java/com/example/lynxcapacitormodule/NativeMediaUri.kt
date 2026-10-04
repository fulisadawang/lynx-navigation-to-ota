package com.example.lynxcapacitormodule

import android.app.Activity
import android.net.Uri
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import java.io.File
import java.net.URLConnection
import java.util.Locale

/** URI 的真实类型、读取授权和私有路径边界集中在本地 IO lane，媒体不会复制成大内联结果。 */
internal object NativeMediaUri {
    data class Media(val uri: Uri, val mimeType: String, val size: Long?, val file: File?)

    fun resolve(activity: Activity, raw: String, directory: String = "CACHE",
        fallbackMime: String = "application/octet-stream", measureSize: Boolean = true): Media {
        require(raw.isNotBlank()) { "需要本地 uri 或 path" }
        val parsed = Uri.parse(raw)
        if (parsed.scheme.equals("content", true)) return read(activity, parsed, fallbackMime, measureSize)
        require(parsed.scheme.isNullOrEmpty() || parsed.scheme.equals("file", true)) { "仅支持本地 content/file URI 或私有路径" }
        val path = if (parsed.scheme.equals("file", true)) requireNotNull(parsed.path) { "file URI 缺少路径" } else raw
        val file = if (path.startsWith('/')) privateFile(activity, File(path)) else {
            val root = when (directory.trim().uppercase(Locale.US)) {
                "CACHE", "TEMPORARY" -> activity.cacheDir
                "FILES", "DATA", "DOCUMENTS", "LIBRARY", "APPLICATION_SUPPORT" -> activity.filesDir
                else -> throw IllegalArgumentException("directory 仅支持 CACHE 和 FILES 私有目录")
            }.canonicalFile
            require(!path.contains('\u0000')) { "path 无效" }
            File(root, path).canonicalFile.also { require(within(it, root)) { "path 超出指定私有目录" } }
        }
        require(file.isFile && file.canRead()) { "本地媒体不存在或不可读取" }
        if (measureSize) NativePayloadBudget.check(file.length(), NativePayloadBudget.DOWNLOAD_BYTES)
        val uri = FileProvider.getUriForFile(activity, NativeFileProviderContract.authority(activity), file)
        val mime = activity.contentResolver.getType(uri) ?: URLConnection.guessContentTypeFromName(file.name)
            ?: fallbackMime
        return Media(uri, mime.lowercase(Locale.US), file.length(), file)
    }

    fun read(activity: Activity, uri: Uri, fallbackMime: String = "application/octet-stream", measureSize: Boolean = true): Media {
        NativeCallContext.checkActive()
        require(uri.scheme.equals("content", true) && !uri.authority.isNullOrBlank()) { "选择结果必须为可读 content URI" }
        val resolver = activity.contentResolver
        val mime = resolver.getType(uri)?.lowercase(Locale.US)
            ?: fallbackMime
        val descriptorSize = resolver.openAssetFileDescriptor(uri, "r")?.use { it.length }
            ?: throw IllegalArgumentException("媒体 URI 不可读取")
        val reportedSize = descriptorSize.takeIf { it >= 0 } ?: resolver.query(
            uri, arrayOf(OpenableColumns.SIZE), null, null, null,
        )?.use { cursor ->
            val column = cursor.getColumnIndex(OpenableColumns.SIZE)
            if (column >= 0 && cursor.moveToFirst() && !cursor.isNull(column)) cursor.getLong(column).takeIf { it >= 0 } else null
        }
        val size = if (reportedSize != null || !measureSize) reportedSize else {
            requireNotNull(resolver.openInputStream(uri)) { "媒体 URI 不可读取" }.use { stream ->
                val buffer = ByteArray(8192)
                var bytes = 0L
                while (true) {
                    NativeCallContext.checkActive()
                    val count = stream.read(buffer)
                    if (count < 0) break
                    bytes += count
                    NativePayloadBudget.check(bytes, NativePayloadBudget.DOWNLOAD_BYTES)
                }
                bytes
            }
        }
        if (measureSize) size?.let { NativePayloadBudget.check(it, NativePayloadBudget.DOWNLOAD_BYTES) }
        return Media(uri, mime, size, null)
    }

    private fun privateFile(activity: Activity, file: File): File = file.canonicalFile.also { candidate ->
        require(listOf(activity.cacheDir, activity.filesDir).any { within(candidate, it.canonicalFile) }) { "文件必须位于 App 私有目录" }
    }

    private fun within(file: File, root: File): Boolean = file == root || file.path.startsWith(root.path + File.separator)
}
