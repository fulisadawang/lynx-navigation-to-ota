package com.example.lynxcapacitormodule

import android.app.Activity
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.core.content.FileProvider
import java.io.BufferedInputStream
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.Locale
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject

/**
 * 当前 Lynx Module 自有的文件下载能力。
 *
 * 下载任务由本类独立持有，Promise 只在任务完成、失败或取消后回调；进度通过 Module 的
 * retained event sender 发出。这里不创建 Capacitor Bridge，也不依赖外部下载插件。
 */
object NativeFileTransferCapabilities {
    private const val PLUGIN_ID = "FileTransfer"
    private const val MAX_DOWNLOAD_BYTES = 20L * 1024L * 1024L
    private const val DEFAULT_TIMEOUT_MS = 30_000
    private const val MIN_TIMEOUT_MS = 1_000
    private const val MAX_TIMEOUT_MS = 120_000

    private val mainHandler = Handler(Looper.getMainLooper())
    private val lock = Any()
    private val transfers = LinkedHashMap<String, Transfer>()

    fun dispatch(
        activity: Activity,
        methodName: String,
        options: JSONObject,
        complete: (JSONObject) -> Unit,
        eventSender: ((String) -> Unit)? = null,
    ): Boolean {
        if (methodName !in HANDLED_METHODS) return false
        when (methodName) {
            "downloadFile" -> startDownload(activity, options, complete, eventSender)
            "getStatus" -> completeSafely(complete, getStatus(options))
            "cancel" -> completeSafely(complete, cancel(activity, options))
        }
        return true
    }

    /** Activity 销毁时取消归属于该 Activity 的任务，并让原始 callback 得到明确结果。 */
    fun release(activity: Activity) {
        val owned = synchronized(lock) {
            transfers.values.filter { it.activity === activity && !it.completed.get() }
        }
        owned.forEach { transfer ->
            transfer.cancelled.set(true)
            transfer.connection?.disconnect()
            completeTransfer(
                transfer,
                error("ACTIVITY_DESTROYED", "Activity 已销毁，文件下载已取消"),
                "failed",
            )
        }
    }

    private fun startDownload(
        activity: Activity,
        options: JSONObject,
        complete: (JSONObject) -> Unit,
        eventSender: ((String) -> Unit)?,
    ) {
        if (!isUsable(activity)) {
            completeSafely(complete, error("ACTIVITY_UNAVAILABLE", "Activity 已失效，无法下载文件"))
            return
        }

        val urlString = options.optString("url").trim()
        val url = runCatching { URL(urlString) }.getOrNull()
        if (url == null || url.protocol.lowercase(Locale.US) !in setOf("http", "https") || url.host.isNullOrBlank()) {
            completeSafely(complete, error("INVALID_ARGUMENT", "只允许下载 http/https URL"))
            return
        }

        val target = resolveTarget(activity, options)
        if (target.error != null) {
            completeSafely(complete, target.error)
            return
        }
        val targetFile = target.file
        if (targetFile != null && targetFile.exists() && targetFile.isDirectory) {
            completeSafely(complete, error("INVALID_ARGUMENT", "下载目标是目录"))
            return
        }
        val temporaryDirectory = File(activity.cacheDir, "lynx-file-transfer")
        val parent = targetFile?.parentFile?.canonicalFile ?: temporaryDirectory.canonicalFile
        if (!parent.exists() && !parent.mkdirs()) {
            completeSafely(complete, error("IO_ERROR", "无法创建下载目录"))
            return
        }
        val operationId = UUID.randomUUID().toString()
        val temporary = if (targetFile != null) {
            File(parent, ".${targetFile.name}.$operationId.part")
        } else {
            File(parent, ".$operationId.part")
        }
        val transfer = Transfer(
            operationId = operationId,
            activity = activity,
            url = urlString,
            targetFile = targetFile,
            targetUri = target.contentUri,
            temporary = temporary,
            complete = complete,
            eventSender = eventSender,
            headers = readHeaders(options),
            timeoutMs = options.optInt("timeout", DEFAULT_TIMEOUT_MS)
                .coerceIn(MIN_TIMEOUT_MS, MAX_TIMEOUT_MS),
        )
        synchronized(lock) {
            transfers[operationId] = transfer
            trimHistoryLocked()
        }
        updateStatus(transfer, JSONObject().put("operationId", operationId).put("state", "pending"))
        Thread({ download(transfer) }, "lynx-file-transfer-$operationId").apply {
            isDaemon = true
            start()
        }
    }

    private fun download(transfer: Transfer) {
        var connection: HttpURLConnection? = null
        try {
            val opened = URL(transfer.url).openConnection()
            if (opened !is HttpURLConnection) throw TransferException("UNSUPPORTED", "下载连接不是 HTTP 连接")
            connection = opened
            transfer.connection = opened
            opened.connectTimeout = transfer.timeoutMs
            opened.readTimeout = transfer.timeoutMs
            opened.instanceFollowRedirects = true
            transfer.headers.forEach { (key, value) -> opened.setRequestProperty(key, value) }

            val responseCode = opened.responseCode
            if (responseCode !in 200..299) {
                throw TransferException("HTTP_ERROR", "下载请求失败，HTTP 状态码：$responseCode")
            }
            val contentLength = opened.contentLengthLong
            if (contentLength > MAX_DOWNLOAD_BYTES) {
                throw TransferException("DOWNLOAD_TOO_LARGE", "下载文件超过 20 MB 限制")
            }

            var total = 0L
            updateStatus(
                transfer,
                JSONObject()
                    .put("operationId", transfer.operationId)
                    .put("state", "running")
                    .put("bytes", 0L)
                    .put("total", if (contentLength >= 0) contentLength else JSONObject.NULL),
            )
            BufferedInputStream(opened.inputStream).use { input ->
                FileOutputStream(transfer.temporary).use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    while (true) {
                        checkNotCancelled(transfer)
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        if (total > MAX_DOWNLOAD_BYTES) {
                            throw TransferException("DOWNLOAD_TOO_LARGE", "下载文件超过 20 MB 限制")
                        }
                        output.write(buffer, 0, count)
                        emitProgress(transfer, total, contentLength)
                    }
                    output.fd.sync()
                }
            }
            checkNotCancelled(transfer)
            if (transfer.targetFile != null) {
                Files.move(
                    transfer.temporary.toPath(),
                    transfer.targetFile.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                )
            } else {
                publishToContentUri(transfer)
            }
            val resultUri = transfer.targetUri ?: fileProviderUri(transfer.activity, requireNotNull(transfer.targetFile))
            completeTransfer(
                transfer,
                JSONObject()
                    .put("operationId", transfer.operationId)
                    .put("state", "completed")
                    .put("path", transfer.targetFile?.absolutePath ?: resultUri.toString())
                    .put("uri", resultUri.toString())
                    .put("size", total),
                "completed",
            )
        } catch (cancelled: TransferCancelledException) {
            transfer.temporary.delete()
            completeTransfer(transfer, error("CANCELLED", cancelled.message ?: "下载已取消"), "cancelled")
        } catch (failure: TransferException) {
            transfer.temporary.delete()
            completeTransfer(transfer, error(failure.code, failure.message ?: "文件下载失败"), "failed")
        } catch (failure: Exception) {
            transfer.temporary.delete()
            completeTransfer(transfer, error("DOWNLOAD_ERROR", failure.message ?: "文件下载失败"), "failed")
        } finally {
            transfer.connection = null
            connection?.disconnect()
            transfer.temporary.delete()
        }
    }

    private fun getStatus(options: JSONObject): JSONObject {
        val operationId = options.optString("operationId").trim()
        if (operationId.isEmpty()) return error("INVALID_ARGUMENT", "getStatus 需要 operationId")
        val transfer = synchronized(lock) { transfers[operationId] }
            ?: return error("NOT_FOUND", "下载任务不存在")
        return JSONObject(transfer.status.toString())
    }

    private fun cancel(activity: Activity, options: JSONObject): JSONObject {
        val operationId = options.optString("operationId").trim()
        if (operationId.isEmpty()) return error("INVALID_ARGUMENT", "cancel 需要 operationId")
        val transfer = synchronized(lock) { transfers[operationId] }
            ?: return error("NOT_FOUND", "下载任务不存在")
        if (transfer.activity !== activity) return error("FORBIDDEN", "不能取消其他 Activity 的下载任务")
        if (transfer.completed.get()) {
            return JSONObject(transfer.status.toString()).put("cancelled", false)
        }
        transfer.cancelled.set(true)
        transfer.connection?.disconnect()
        return JSONObject()
            .put("operationId", operationId)
            .put("state", "cancelling")
            .put("cancelled", true)
    }

    private fun resolveTarget(activity: Activity, options: JSONObject): TargetResolution {
        val raw = options.optString("path").trim()
        if (raw.isEmpty()) return TargetResolution(error = error("INVALID_ARGUMENT", "downloadFile 需要目标 path"))
        val parsed = Uri.parse(raw)
        if (parsed.scheme.equals("content", ignoreCase = true)) {
            if (parsed.authority.isNullOrBlank()) {
                return TargetResolution(error = error("INVALID_ARGUMENT", "content URI 缺少 authority"))
            }
            return TargetResolution(contentUri = parsed)
        }
        val root = when (parsed.scheme?.lowercase(Locale.US)) {
            null, "" -> directoryRoot(activity, options.optString("directory", "CACHE"))
            "file" -> null
            else -> return TargetResolution(error = error("INVALID_ARGUMENT", "path 只支持相对路径或 file URI"))
        }
        val candidate = if (root != null) {
            safeResolve(root, raw)
        } else {
            val absolute = parsed.path ?: return TargetResolution(error = error("INVALID_ARGUMENT", "file URI 缺少路径"))
            privateFile(activity, absolute)
        }
        return if (candidate == null) {
            TargetResolution(error = error("INVALID_ARGUMENT", "下载目标必须位于 app 私有目录"))
        } else {
            TargetResolution(file = candidate)
        }
    }

    private fun directoryRoot(activity: Activity, directory: String): File? = when (directory.trim().uppercase(Locale.US)) {
        "CACHE", "TEMPORARY" -> activity.cacheDir
        "FILES", "DATA", "DOCUMENTS", "LIBRARY", "APPLICATION_SUPPORT" -> activity.filesDir
        else -> null
    }

    private fun safeResolve(root: File?, raw: String): File? {
        if (root == null || raw.startsWith('/') || raw.contains('\u0000')) return null
        val canonicalRoot = runCatching { root.canonicalFile }.getOrNull() ?: return null
        val candidate = runCatching { File(canonicalRoot, raw).canonicalFile }.getOrNull() ?: return null
        return candidate.takeIf { isWithin(it, canonicalRoot) }
    }

    private fun privateFile(activity: Activity, path: String): File? {
        val candidate = runCatching { File(path).canonicalFile }.getOrNull() ?: return null
        val roots = listOf(activity.cacheDir, activity.filesDir).mapNotNull { runCatching { it.canonicalFile }.getOrNull() }
        return candidate.takeIf { file -> roots.any { root -> isWithin(file, root) } }
    }

    private fun isWithin(file: File, root: File): Boolean =
        file == root || file.path.startsWith(root.path + File.separator)

    private fun publishToContentUri(transfer: Transfer) {
        val targetUri = transfer.targetUri ?: throw TransferException("INVALID_ARGUMENT", "下载目标 URI 缺失")
        val output = transfer.activity.contentResolver.openOutputStream(targetUri, "w")
            ?: throw TransferException("IO_ERROR", "无法打开 content URI 输出流")
        transfer.temporary.inputStream().use { input -> output.use { input.copyTo(it) } }
    }

    private fun fileProviderUri(activity: Activity, file: File): Uri {
        val authority = NativeFileProviderContract.authority(activity)
        return FileProvider.getUriForFile(activity, authority, file)
    }

    private fun readHeaders(options: JSONObject): Map<String, String> {
        val source = options.optJSONObject("headers") ?: options.optJSONObject("requestHeaders") ?: return emptyMap()
        val result = linkedMapOf<String, String>()
        val keys = source.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            val value = source.opt(key)
            if (value != null && value !== JSONObject.NULL) result[key] = value.toString()
        }
        return result
    }

    private fun updateStatus(transfer: Transfer, status: JSONObject) {
        transfer.status = status
        emitEvent(
            transfer,
            JSONObject()
                .put("pluginId", PLUGIN_ID)
                .put("methodName", "progress")
                .put("eventName", "progress")
                .put("save", true)
                .put("data", status),
        )
    }

    private fun emitProgress(transfer: Transfer, bytes: Long, total: Long) {
        val progress = JSONObject()
            .put("operationId", transfer.operationId)
            .put("state", "running")
            .put("bytes", bytes)
            .put("total", if (total >= 0) total else JSONObject.NULL)
        transfer.status = progress
        emitEvent(
            transfer,
            JSONObject()
                .put("pluginId", PLUGIN_ID)
                .put("methodName", "progress")
                .put("eventName", "progress")
                .put("save", true)
                .put("data", progress),
        )
    }

    private fun emitEvent(transfer: Transfer, event: JSONObject) {
        runCatching { transfer.eventSender?.invoke(event.toString()) }
    }

    private fun completeTransfer(transfer: Transfer, result: JSONObject, state: String) {
        if (!transfer.completed.compareAndSet(false, true)) return
        val status = if (result.has("error")) {
            JSONObject(result.toString()).put("operationId", transfer.operationId).put("state", state)
        } else {
            result
        }
        transfer.status = status
        val deliver = Runnable { completeSafely(transfer.complete, result) }
        if (Looper.myLooper() == Looper.getMainLooper()) deliver.run() else mainHandler.post(deliver)
    }

    private fun checkNotCancelled(transfer: Transfer) {
        if (transfer.cancelled.get()) throw TransferCancelledException("下载已取消")
    }

    private fun trimHistoryLocked() {
        while (transfers.size > 32) {
            val first = transfers.entries.firstOrNull { it.value.completed.get() } ?: break
            transfers.remove(first.key)
        }
    }

    private fun isUsable(activity: Activity): Boolean = !activity.isFinishing && !activity.isDestroyed

    private fun completeSafely(complete: (JSONObject) -> Unit, result: JSONObject) {
        runCatching { complete(result) }
    }

    private fun error(code: String, message: String): JSONObject = JSONObject()
        .put("error", JSONObject().put("code", code).put("message", message))

    private data class TargetResolution(
        val file: File? = null,
        val contentUri: Uri? = null,
        val error: JSONObject? = null,
    )

    private class Transfer(
        val operationId: String,
        val activity: Activity,
        val url: String,
        val targetFile: File?,
        val targetUri: Uri?,
        val temporary: File,
        val complete: (JSONObject) -> Unit,
        val eventSender: ((String) -> Unit)?,
        val headers: Map<String, String>,
        val timeoutMs: Int,
    ) {
        val cancelled = AtomicBoolean(false)
        val completed = AtomicBoolean(false)
        @Volatile var connection: HttpURLConnection? = null
        @Volatile var status: JSONObject = JSONObject().put("operationId", operationId).put("state", "pending")
    }

    private class TransferException(val code: String, message: String) : Exception(message)
    private class TransferCancelledException(message: String) : Exception(message)

    private val HANDLED_METHODS = setOf("downloadFile", "getStatus", "cancel")
}
