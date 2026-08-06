package com.example.lynxshell.bridge

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.os.Bundle
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.util.UUID

/**
 * 无界面的系统媒体选择中转页。
 *
 * 使用独立 Activity 是为了遵守 Activity Result 的生命周期要求；LynxModule
 * 往往在宿主 Activity 已经 STARTED 后才创建，届时再注册 launcher 会直接失败。
 */
class ShellMediaPickerActivity : AppCompatActivity() {
    private var pickerLaunched = false

    private val pickerLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        if (result.resultCode != Activity.RESULT_OK) {
            ShellMediaPickerCoordinator.failure("用户取消了媒体选择")
            finish()
            return@registerForActivityResult
        }

        val options = runCatching {
            JSONObject(intent.getStringExtra(EXTRA_OPTIONS_JSON).orEmpty())
        }.getOrElse {
            ShellMediaPickerCoordinator.failure("媒体参数不是合法 JSON Object")
            finish()
            return@registerForActivityResult
        }
        Thread {
            val picked = runCatching { makePickedFiles(result.data, options) }
            runOnUiThread {
                picked.onSuccess { files ->
                    ShellMediaPickerCoordinator.success(
                        hashMapOf("tempFiles" to ArrayList(files)),
                    )
                }.onFailure {
                    ShellMediaPickerCoordinator.failure(it.message ?: "无法读取所选媒体")
                }
                finish()
            }
        }.start()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pickerLaunched = savedInstanceState?.getBoolean(STATE_PICKER_LAUNCHED) ?: false
        if (!ShellMediaPickerCoordinator.hasPending()) {
            finish()
            return
        }
        if (pickerLaunched) return

        val options = runCatching {
            JSONObject(intent.getStringExtra(EXTRA_OPTIONS_JSON).orEmpty())
        }.getOrElse {
            ShellMediaPickerCoordinator.failure("媒体参数不是合法 JSON Object")
            finish()
            return
        }

        runCatching {
            pickerLaunched = true
            pickerLauncher.launch(makePickerIntent(options))
        }.onFailure {
            ShellMediaPickerCoordinator.failure(it.message ?: "无法打开系统媒体选择器")
            finish()
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean(STATE_PICKER_LAUNCHED, pickerLaunched)
        super.onSaveInstanceState(outState)
    }

    private fun makePickerIntent(options: JSONObject): Intent {
        val sourceType = options.optString("sourceType", "album")
        val mediaTypes = options.optJSONArray("mediaTypes")
            ?.let { array ->
                buildSet {
                    for (index in 0 until array.length()) add(array.optString(index))
                }
            }
            ?.filter { it == "image" || it == "video" }
            ?.toSet()
            .orEmpty()
            .ifEmpty { setOf("image") }

        if (sourceType == "camera") {
            // 同时选择 image/video 时优先图片；系统相机 Intent 一次只能声明一种拍摄模式。
            return Intent(
                if (mediaTypes == setOf("video")) {
                    MediaStore.ACTION_VIDEO_CAPTURE
                } else {
                    MediaStore.ACTION_IMAGE_CAPTURE
                },
            )
        }

        val mimeTypes = buildList {
            if ("image" in mediaTypes) add("image/*")
            if ("video" in mediaTypes) add("video/*")
        }
        return Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = if (mimeTypes.size == 1) mimeTypes.first() else "*/*"
            if (mimeTypes.size > 1) {
                putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.toTypedArray())
            }
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, options.optInt("maxCount", 1) > 1)
        }
    }

    private fun makePickedFiles(
        resultIntent: Intent?,
        options: JSONObject,
    ): List<HashMap<String, Any>> {
        val maxCount = options.optInt("maxCount", 1).coerceIn(1, 20)
        val uris = buildList {
            resultIntent?.clipData?.let { clip ->
                for (index in 0 until minOf(clip.itemCount, maxCount)) {
                    add(clip.getItemAt(index).uri)
                }
            }
            if (isEmpty()) resultIntent?.data?.let(::add)
        }

        if (uris.isNotEmpty()) {
            return uris.take(maxCount).map(::copyPickedUri)
        }

        @Suppress("DEPRECATION")
        val bitmap = resultIntent?.extras?.get("data") as? Bitmap
        requireNotNull(bitmap) { "系统选择器没有返回可读取的媒体文件" }
        val directory = mediaDirectory()
        val output = File(directory, "lynx-image-${UUID.randomUUID()}.jpg")
        output.outputStream().use { stream ->
            require(bitmap.compress(Bitmap.CompressFormat.JPEG, 92, stream)) { "相机图片保存失败" }
        }
        return listOf(fileResult(output, "image/jpeg"))
    }

    private fun copyPickedUri(uri: Uri): HashMap<String, Any> {
        val mimeType = contentResolver.getType(uri) ?: "application/octet-stream"
        val displayName = queryDisplayName(uri)
        val extension = MimeTypeMap.getSingleton().getExtensionFromMimeType(mimeType)
            ?: displayName.substringAfterLast('.', "").takeIf(::isSafeExtension)
            ?: "bin"
        val output = File(mediaDirectory(), "lynx-media-${UUID.randomUUID()}.$extension")
        runCatching {
            openInput(uri).use { input ->
                output.outputStream().use { stream ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    var total = 0L
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        require(total <= MAX_FILE_BYTES) { "所选文件超过 20 MB 限制" }
                        stream.write(buffer, 0, count)
                    }
                }
            }
        }.onFailure {
            output.delete()
            throw it
        }
        return fileResult(output, mimeType)
    }

    private fun openInput(uri: Uri): InputStream =
        if (uri.scheme.equals("file", ignoreCase = true)) {
            File(requireNotNull(uri.path) { "媒体文件路径无效" }).inputStream()
        } else {
            requireNotNull(contentResolver.openInputStream(uri)) { "无法读取所选媒体" }
        }

    private fun fileResult(file: File, mimeType: String): HashMap<String, Any> =
        hashMapOf(
            "tempFilePath" to Uri.fromFile(file).toString(),
            "tempFileAbsolutePath" to file.absolutePath,
            "size" to file.length(),
            "mediaType" to if (mimeType.startsWith("video/")) "video" else "image",
            "mimeType" to mimeType,
        )

    private fun mediaDirectory(): File =
        File(cacheDir, "lynx-media").apply { mkdirs() }

    private fun queryDisplayName(uri: Uri): String {
        if (!uri.scheme.equals("content", ignoreCase = true)) {
            return uri.lastPathSegment.orEmpty()
        }
        return contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0).orEmpty() else ""
        }.orEmpty()
    }

    private fun isSafeExtension(value: String): Boolean =
        Regex("^[A-Za-z0-9]{1,10}$").matches(value)

    companion object {
        const val EXTRA_OPTIONS_JSON = "lynx_shell.media_options_json"
        private const val STATE_PICKER_LAUNCHED = "picker_launched"
        private const val MAX_FILE_BYTES = 20L * 1024L * 1024L
    }
}
