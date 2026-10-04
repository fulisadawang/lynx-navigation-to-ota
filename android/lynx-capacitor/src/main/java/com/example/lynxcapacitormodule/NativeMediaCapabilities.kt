package com.example.lynxcapacitormodule

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Looper
import android.os.Handler
import android.util.Base64
import androidx.core.content.FileProvider
import java.io.File
import java.nio.charset.StandardCharsets
import java.util.Locale
import org.json.JSONArray
import org.json.JSONObject

/**
 * LynxCapacitorModule 的媒体和文件能力。
 *
 * 这里故意只依赖 Android framework 和当前 Module 已有的 AndroidX。返回值是业务结果对象，
 * 不包含 dispatcher 层的 success envelope；未处理的 pluginId 返回 null。
 */
object NativeMediaCapabilities {
    private const val DEFAULT_DIRECTORY = "CACHE"

    /** 分发本能力域；其它 pluginId 返回 null。 */
    fun dispatch(
        activity: Activity,
        pluginId: String,
        methodName: String,
        options: JSONObject,
    ): JSONObject? {
        if (pluginId !in HANDLED_PLUGIN_IDS) return null

        return runCatching {
            when (pluginId) {
                "Filesystem" -> filesystem(activity, methodName, options)
                "FileViewer" -> fileViewer(activity, methodName, options)
                "Clipboard" -> clipboard(activity, methodName, options)
                else -> null
            }
        }.getOrElse { error ->
            failure(if (error is NativeBudgetExceeded) error.code else if (error is NativeCallCancelled) "HOST_DESTROYED" else "NATIVE_ERROR", error.message ?: "Android native call failed")
        }
    }

    private fun filesystem(activity: Activity, methodName: String, options: JSONObject): JSONObject {
        if (methodName !in FILESYSTEM_METHODS) {
            return failure("UNSUPPORTED", "Filesystem.$methodName 尚未接入当前 Android Module")
        }
        val root = when (val result = resolveDirectory(activity, options)) {
            is DirectoryResolution.Valid -> result.file
            is DirectoryResolution.Invalid -> return result.error
        }
        val path = options.optString("path").trim()
        val target = safeResolve(root, path, requireNonEmpty = methodName != "readdir")
            ?: return failure("INVALID_ARGUMENT", "path 必须是目录内的相对安全路径")

        return when (methodName) {
            "writeFile" -> writeFile(target, options)
            "readFile" -> readFile(target, options)
            "readdir" -> readDirectory(target)
            "stat" -> stat(target)
            "mkdir" -> makeDirectory(target, options)
            "getUri" -> getFileUri(activity, target, options)
            else -> failure("UNSUPPORTED", "Filesystem.$methodName 尚未接入当前 Android Module")
        }
    }

    private fun writeFile(target: File, options: JSONObject): JSONObject {
        if (target.exists() && target.isDirectory) {
            return failure("INVALID_ARGUMENT", "目标路径是目录")
        }
        val data = options.optString("data")
        val bytes = when (options.optString("encoding", "utf8").trim().lowercase(Locale.US)) {
            "utf8", "utf-8", "text" -> data.toByteArray(StandardCharsets.UTF_8)
            "base64" -> decodeBase64(data, Base64.DEFAULT)
            "base64url" -> decodeBase64(data, Base64.URL_SAFE or Base64.NO_WRAP)
            else -> return failure("UNSUPPORTED_ENCODING", "仅支持 UTF-8 和 Base64 编码")
        }

        NativePayloadBudget.check(bytes.size.toLong(), NativePayloadBudget.INLINE_BYTES.toLong())
        return runCatching {
            NativeAtomicFile.write(target, bytes)
            JSONObject()
                .put("written", true)
                .put("uri", target.toURI().toString())
        }.getOrElse { error ->
            failure(if (error is NativeBudgetExceeded) error.code else if (error is NativeCallCancelled) "HOST_DESTROYED" else "IO_ERROR", error.message ?: "写入文件失败")
        }
    }

    private fun decodeBase64(data: String, flags: Int): ByteArray = try {
        Base64.decode(data, flags)
    } catch (error: IllegalArgumentException) {
        throw IllegalArgumentException("Base64 数据无效", error)
    }

    private fun readFile(target: File, options: JSONObject): JSONObject {
        if (!target.exists()) return failure("NOT_FOUND", "文件不存在")
        if (!target.isFile) return failure("INVALID_ARGUMENT", "目标路径不是文件")

        return runCatching {
            NativePayloadBudget.check(target.length(), NativePayloadBudget.INLINE_BYTES.toLong())
            val bytes = target.inputStream().use { NativePayloadBudget.read(it) }
            val data = when (options.optString("encoding", "utf8").trim().lowercase(Locale.US)) {
                "utf8", "utf-8", "text" -> String(bytes, StandardCharsets.UTF_8)
                "base64" -> Base64.encodeToString(bytes, Base64.NO_WRAP)
                "base64url" -> Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_WRAP)
                else -> return failure("UNSUPPORTED_ENCODING", "仅支持 UTF-8 和 Base64 编码")
            }
            JSONObject().put("data", data)
        }.getOrElse { error ->
            failure(if (error is NativeBudgetExceeded) error.code else if (error is NativeCallCancelled) "HOST_DESTROYED" else "IO_ERROR", error.message ?: "读取文件失败")
        }
    }

    private fun readDirectory(target: File): JSONObject {
        if (!target.exists()) return failure("NOT_FOUND", "目录不存在")
        if (!target.isDirectory) return failure("INVALID_ARGUMENT", "目标路径不是目录")

        return JSONObject().put("files", NativeDirectoryIO.read(target))
    }

    private fun stat(target: File): JSONObject {
        if (!target.exists()) return failure("NOT_FOUND", "文件或目录不存在")
        return fileSummary(target)
    }

    private fun makeDirectory(target: File, options: JSONObject): JSONObject {
        if (target.exists()) {
            return if (target.isDirectory) {
                JSONObject().put("created", false).put("uri", target.toURI().toString())
            } else {
                failure("INVALID_ARGUMENT", "目标路径已被文件占用")
            }
        }

        val recursive = options.optBoolean("recursive", false)
        val created = if (recursive) {
            target.mkdirs()
        } else if (target.parentFile?.isDirectory == true) {
            target.mkdir()
        } else {
            return failure("PARENT_NOT_FOUND", "父目录不存在；请设置 recursive=true")
        }
        return if (created || target.isDirectory) {
            JSONObject().put("created", created).put("uri", target.toURI().toString())
        } else {
            failure("IO_ERROR", "创建目录失败")
        }
    }

    private fun fileSummary(file: File): JSONObject = NativeDirectoryIO.summary(file)

    private fun getFileUri(activity: Activity, target: File, options: JSONObject): JSONObject {
        val authority = options.optString("fileProviderAuthority").trim().ifEmpty {
            NativeFileProviderContract.authority(activity)
        }
        val uri = runCatching { FileProvider.getUriForFile(activity, authority, target) }
            .getOrElse { return failure("FILE_PROVIDER_NOT_CONFIGURED", "无法生成安全的 content URI") }
        return JSONObject().put("uri", uri.toString()).put("path", target.absolutePath)
    }

    internal fun openDocument(activity: Activity, options: JSONObject, complete: (JSONObject) -> Unit) {
        if (options.has("items")) {
            NativeImagePreviewCapabilities.open(activity, options, complete)
            return
        }
        if (options.has("initialIndex")) { complete(failure("INVALID_ARGUMENT", "initialIndex 只能与 items 一起使用")); return }
        val owner = NativeCallContext.owner
        NativeIO.local.submit(owner, { complete(failure("BUSY", "文档读取队列已满")) }) {
            try {
                val raw = firstNonBlank(options, "path", "localPath", "uri")
                    ?: throw IllegalArgumentException("需要本地 path 或 uri")
                val media = NativeMediaUri.resolve(activity, raw, options.optString("directory", "CACHE"),
                    options.optString("mimeType").ifBlank { "application/octet-stream" }, measureSize = false)
                Handler(Looper.getMainLooper()).post {
                    if (owner?.isActive == false) return@post
                    NativeCallContext.withOwner(owner) {
                        val result = openDocumentOnMain(activity, media)
                        complete(result)
                    }
                }
            } catch (error: Exception) {
                complete(failure(if (error is NativeBudgetExceeded) error.code else "INVALID_ARGUMENT", error.message ?: "本地文档不可读取"))
            }
        }
    }

    private fun fileViewer(activity: Activity, methodName: String, options: JSONObject): JSONObject {
        if (methodName != "openDocumentFromLocalPath") return failure("UNSUPPORTED", "FileViewer.$methodName 尚未接入")
        if (Looper.myLooper() != Looper.getMainLooper()) return failure("UI_THREAD_REQUIRED", "打开文档必须在主线程调用")
        val raw = firstNonBlank(options, "path", "localPath", "uri") ?: return failure("INVALID_ARGUMENT", "需要本地 path 或 uri")
        val media = NativeMediaUri.resolve(activity, raw, options.optString("directory", "CACHE"),
            options.optString("mimeType").ifBlank { "application/octet-stream" }, measureSize = false)
        return openDocumentOnMain(activity, media)
    }

    private fun openDocumentOnMain(activity: Activity, media: NativeMediaUri.Media): JSONObject {
        if (activity.isFinishing || activity.isDestroyed) return failure("HOST_DESTROYED", "文档宿主已销毁")
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(media.uri, media.mimeType)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            clipData = ClipData.newRawUri("lynx-document", media.uri)
        }
        if (intent.resolveActivity(activity.packageManager) == null) return failure("NO_HANDLER", "系统没有可打开该文件类型的应用")
        return try {
            activity.startActivity(intent)
            JSONObject().put("opened", true).put("uri", media.uri.toString()).put("mimeType", media.mimeType)
        } catch (error: Exception) { failure("OPEN_ERROR", error.message ?: "打开本地文档失败") }
    }

    private fun clipboard(activity: Activity, methodName: String, options: JSONObject): JSONObject {
        val manager = activity.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            ?: return failure("UNAVAILABLE", "系统剪贴板不可用")
        return when (methodName) {
            "write" -> {
                val value = firstNonBlank(options, "string", "text") ?: ""
                val label = options.optString("label", "lynx")
                manager.setPrimaryClip(ClipData.newPlainText(label, value))
                JSONObject().put("written", true)
            }
            "read" -> {
                val clip = manager.primaryClip
                val value = if (clip != null && clip.itemCount > 0) {
                    clip.getItemAt(0).coerceToText(activity).toString()
                } else {
                    ""
                }
                JSONObject().put("type", "text").put("value", value)
            }
            else -> failure("UNSUPPORTED", "Clipboard.$methodName 尚未接入当前 Android Module")
        }
    }

    private fun resolveDirectory(activity: Activity, options: JSONObject): DirectoryResolution {
        val directory = options.optString("directory", DEFAULT_DIRECTORY).trim().uppercase(Locale.US)
        val file = when (directory) {
            "CACHE", "TEMPORARY" -> activity.cacheDir
            "FILES", "DATA", "DOCUMENTS", "LIBRARY", "APPLICATION_SUPPORT" -> activity.filesDir
            else -> return DirectoryResolution.Invalid(
                failure(
                    "DIRECTORY_UNSUPPORTED",
                    "当前 Android Module 仅支持 CACHE 和 FILES 目录映射",
                ),
            )
        }
        return DirectoryResolution.Valid(file.canonicalFile)
    }

    private fun safeResolve(root: File, rawPath: String, requireNonEmpty: Boolean): File? {
        val path = rawPath.trim()
        if (requireNonEmpty && path.isEmpty()) return null
        if (path.contains('\u0000') || path.startsWith('/') || path.split('/').any { it == ".." }) return null
        val canonicalRoot = runCatching { root.canonicalFile }.getOrNull() ?: return null
        val candidate = runCatching { File(canonicalRoot, path).canonicalFile }.getOrNull() ?: return null
        return candidate.takeIf { isWithinRoot(it, canonicalRoot) }
    }

    private fun isWithinRoot(candidate: File, root: File): Boolean {
        val candidatePath = candidate.path
        val rootPath = root.path.trimEnd(File.separatorChar)
        return candidatePath == rootPath || candidatePath.startsWith("$rootPath${File.separator}")
    }

    private fun firstNonBlank(options: JSONObject, vararg names: String): String? = names
        .asSequence()
        .map { options.optString(it).trim() }
        .firstOrNull { it.isNotEmpty() }

    private fun failure(code: String, message: String): JSONObject = JSONObject()
        .put("error", JSONObject().put("code", code).put("message", message))

    private sealed interface DirectoryResolution {
        data class Valid(val file: File) : DirectoryResolution
        data class Invalid(val error: JSONObject) : DirectoryResolution
    }

    private val HANDLED_PLUGIN_IDS = setOf(
        "Filesystem",
        "FileTransfer",
        "FileViewer",
        "Clipboard",
    )

    private val FILESYSTEM_METHODS = setOf(
        "writeFile",
        "readFile",
        "readdir",
        "stat",
        "mkdir",
        "getUri",
    )
}
