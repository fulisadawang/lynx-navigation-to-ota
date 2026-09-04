package com.example.lynxcapacitormodule

import android.Manifest
import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import android.util.Base64
import android.util.Log
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.FileProvider
import androidx.core.content.ContextCompat
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject

/**
 * 自有 Android 拍照页面。
 *
 * 页面只使用 CameraX 和 Android MediaStore：预览、拍照、取消与结果回传都不经过
 * Capacitor 或任何外部项目。调用方通过 requestId 关联 pending callback，输出参数用于
 * 决定 MediaStore 的文件名、相册目录和 MIME 类型。
 */
class PhotoCaptureActivity : AppCompatActivity() {
    companion object {
        private const val TAG = "LynxNativeModule"
        const val EXTRA_OUTPUT_DISPLAY_NAME = "com.example.lynxcapacitormodule.camera.OUTPUT_DISPLAY_NAME"
        const val EXTRA_OUTPUT_RELATIVE_PATH = "com.example.lynxcapacitormodule.camera.OUTPUT_RELATIVE_PATH"
        const val EXTRA_OUTPUT_MIME_TYPE = "com.example.lynxcapacitormodule.camera.OUTPUT_MIME_TYPE"
        const val EXTRA_LENS_FACING = "com.example.lynxcapacitormodule.camera.LENS_FACING"
        const val EXTRA_RESULT_TYPE = "com.example.lynxcapacitormodule.camera.RESULT_TYPE"
        const val EXTRA_SAVE_TO_GALLERY = "com.example.lynxcapacitormodule.camera.SAVE_TO_GALLERY"

        private const val CAMERA_PERMISSION_REQUEST_CODE = 47_101
        private const val DEFAULT_RELATIVE_PATH = "Pictures/LynxCamera"
        private const val DEFAULT_MIME_TYPE = "image/jpeg"
        private const val MAX_INLINE_IMAGE_BYTES = 20 * 1024 * 1024
    }

    private val completed = AtomicBoolean(false)
    private val captureInProgress = AtomicBoolean(false)

    private var requestId = ""
    private var outputDisplayName = ""
    private var outputRelativePath = DEFAULT_RELATIVE_PATH
    private var outputMimeType = DEFAULT_MIME_TYPE
    private var resultType = "URI"
    private var saveToGallery = true
    private var lensFacing = CameraSelector.LENS_FACING_BACK
    private var previewView: PreviewView? = null
    private var captureButton: Button? = null
    private var cameraProvider: ProcessCameraProvider? = null
    private var imageCapture: ImageCapture? = null
    private var boundPreview: Preview? = null
    private var boundImageCapture: ImageCapture? = null
    private var cameraOperationAcquired = false
    private var pendingOutput: PendingOutput? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        readLaunchArguments()
        if (requestId.isBlank()) {
            finishWith(error("INVALID_ARGUMENT", "拍照 Activity 缺少 requestId"))
            return
        }

        runCatching {
            setContentView(createContentView())
            onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() {
                    finishWith(error("CANCELLED", "用户取消了拍照"))
                }
            })
            ensureCameraPermissionAndStart()
        }.onFailure { throwable ->
            finishWith(error("UNAVAILABLE", throwable.message ?: "无法创建拍照页面"))
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != CAMERA_PERMISSION_REQUEST_CODE) return
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            startCamera()
        } else {
            finishWith(error("PERMISSION_DENIED", "用户未授予相机权限"))
        }
    }

    override fun onDestroy() {
        unbindBoundUseCases()
        if (cameraOperationAcquired) {
            NativeCameraXConfiguration.releaseOperation()
            cameraOperationAcquired = false
        }
        if (!isChangingConfigurations && !completed.get()) {
            finishWith(error("ACTIVITY_DESTROYED", "拍照 Activity 已销毁"), callFinish = false)
        }
        super.onDestroy()
    }

    private fun readLaunchArguments() {
        requestId = intent.getStringExtra(NativeCameraCaptureCapabilities.EXTRA_REQUEST_ID).orEmpty().trim()
        outputDisplayName = intent.getStringExtra(EXTRA_OUTPUT_DISPLAY_NAME)
            .orEmpty()
            .trim()
            .replace('/', '_')
            .replace('\\', '_')
            .take(120)
        outputRelativePath = intent.getStringExtra(EXTRA_OUTPUT_RELATIVE_PATH)
            .orEmpty()
            .trim()
            .trim('/')
            .ifBlank { DEFAULT_RELATIVE_PATH }
            .take(240)
        outputMimeType = intent.getStringExtra(EXTRA_OUTPUT_MIME_TYPE)
            .orEmpty()
            .trim()
            .lowercase()
            .takeIf { it.startsWith("image/") }
            ?: DEFAULT_MIME_TYPE
        resultType = intent.getStringExtra(EXTRA_RESULT_TYPE)
            .orEmpty()
            .trim()
            .uppercase()
            .ifBlank { "URI" }
        saveToGallery = intent.getBooleanExtra(EXTRA_SAVE_TO_GALLERY, true)
        lensFacing = intent.getIntExtra(EXTRA_LENS_FACING, CameraSelector.LENS_FACING_BACK)
            .takeIf { it == CameraSelector.LENS_FACING_BACK || it == CameraSelector.LENS_FACING_FRONT }
            ?: CameraSelector.LENS_FACING_BACK
    }

    private fun ensureCameraPermissionAndStart() {
        if (!isCameraPermissionDeclared()) {
            finishWith(error("PERMISSION_NOT_DECLARED", "宿主 Manifest 未声明 android.permission.CAMERA"))
            return
        }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            startCamera()
            return
        }
        runCatching {
            requestPermissions(arrayOf(Manifest.permission.CAMERA), CAMERA_PERMISSION_REQUEST_CODE)
        }.onFailure { throwable ->
            finishWith(error("PERMISSION_DENIED", throwable.message ?: "无法请求相机权限"))
        }
    }

    private fun startCamera() {
        if (completed.get() || isFinishing || isDestroyed) return
        if (!cameraOperationAcquired) {
            if (!NativeCameraXConfiguration.tryAcquireOperation()) {
                finishWith(error("BUSY", "设备已有其他相机操作正在进行"))
                return
            }
            cameraOperationAcquired = true
        }
        runCatching {
            val providerFuture = ProcessCameraProvider.getInstance(this)
            providerFuture.addListener({
                runCatching { providerFuture.get() }
                    .onSuccess(::bindCamera)
                    .onFailure { throwable ->
                        finishWith(error("CAMERA_UNAVAILABLE", throwable.message ?: "无法获取 CameraX 相机"))
                    }
            }, ContextCompat.getMainExecutor(this))
        }.onFailure { throwable ->
            finishWith(error("CAMERA_UNAVAILABLE", throwable.message ?: "无法初始化 CameraX"))
        }
    }

    private fun bindCamera(provider: ProcessCameraProvider) {
        if (completed.get() || isFinishing || isDestroyed) return
        val selector = CameraSelector.Builder().requireLensFacing(lensFacing).build()
        if (!runCatching { provider.hasCamera(selector) }.getOrDefault(false)) {
            val direction = if (lensFacing == CameraSelector.LENS_FACING_FRONT) "前" else "后"
            finishWith(error("CAMERA_UNAVAILABLE", "设备没有可用的${direction}摄像头"))
            return
        }

        val preview = Preview.Builder().build().apply {
            setSurfaceProvider(previewView?.surfaceProvider)
        }
        val capture = ImageCapture.Builder()
            .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
            .build()

        runCatching {
            unbindBoundUseCases()
            provider.bindToLifecycle(this, selector, preview, capture)
            cameraProvider = provider
            imageCapture = capture
            boundPreview = preview
            boundImageCapture = capture
            captureButton?.isEnabled = true
        }.onFailure { throwable ->
            finishWith(error("CAMERA_UNAVAILABLE", throwable.message ?: "无法绑定 CameraX 预览"))
        }
    }

    private fun capturePhoto() {
        if (completed.get() || !captureInProgress.compareAndSet(false, true)) return
        captureButton?.isEnabled = false
        val capture = imageCapture
        if (capture == null) {
            finishWith(error("CAMERA_UNAVAILABLE", "相机预览尚未就绪"))
            return
        }

        val output = createPendingOutput()
        if (output == null) {
            finishWith(error("IO", "无法创建图片输出文件"))
            return
        }
        pendingOutput = output
        // 先落到 app cache 临时文件，规避部分模拟器 MediaStore provider 对直接 URI
        // 写入的兼容问题；拍摄完成后再把文件发布到 MediaStore。
        val options = ImageCapture.OutputFileOptions.Builder(output.tempFile).build()
        capture.takePicture(
            options,
            ContextCompat.getMainExecutor(this),
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(outputFileResults: ImageCapture.OutputFileResults) {
                    // CameraX 先写 cache 文件；只有 saveToGallery=true 才继续发布到 MediaStore。
                    val savedUri = output.uri
                    Log.i(TAG, "PHOTO_CAPTURE_SAVED temp=${output.tempFile.absolutePath} exists=${output.tempFile.exists()} length=${output.tempFile.length()} uri=$savedUri")
                    runCatching {
                        if (output.isMediaStore) {
                            publishOutput(output)
                            finalizeOutput(output)
                        }
                        pendingOutput = null
                        if (output.isMediaStore) output.tempFile.delete()
                        finishWith(success(savedUri))
                    }.onFailure { throwable ->
                        cleanupPendingOutput()
                        finishWith(error("IO", throwable.message ?: "无法提交 MediaStore 图片"))
                    }
                }

                override fun onError(exception: ImageCaptureException) {
                    Log.e(TAG, "PHOTO_CAPTURE_ERROR code=${exception.imageCaptureError} temp=${output.tempFile.absolutePath} exists=${output.tempFile.exists()} length=${output.tempFile.length()}", exception)
                    cleanupPendingOutput()
                    finishWith(error("CAPTURE_FAILED", exception.message ?: "CameraX 拍照失败"))
                }
            },
        )
    }

    private fun createPendingOutput(): PendingOutput? {
        val displayName = outputDisplayName.ifBlank {
            "lynx-camera-${UUID.randomUUID()}.jpg"
        }.let { name ->
            if (name.substringAfterLast('.', "").isBlank()) "$name.jpg" else name
        }
        val temporaryDirectory = File(cacheDir, "lynx-camera")
        if (!temporaryDirectory.exists() && !temporaryDirectory.mkdirs() && !temporaryDirectory.isDirectory) {
            return null
        }
        val temporaryFile = File(temporaryDirectory, "capture-${UUID.randomUUID()}.jpg")
        if (!runCatching { temporaryFile.createNewFile() }.getOrDefault(false) || !temporaryFile.isFile) {
            return null
        }

        if (!saveToGallery) {
            val uri = runCatching {
                FileProvider.getUriForFile(this, NativeFileProviderContract.authority(this), temporaryFile)
            }.getOrElse {
                temporaryFile.delete()
                return null
            }
            return PendingOutput(uri, temporaryFile, isPending = false, isMediaStore = false)
        }

        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
            put(MediaStore.Images.Media.MIME_TYPE, outputMimeType)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.Images.Media.RELATIVE_PATH, outputRelativePath)
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
        }
        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }
        val uri = runCatching { contentResolver.insert(collection, values) }.getOrElse {
            temporaryFile.delete()
            return null
        } ?: run {
            temporaryFile.delete()
            return null
        }
        return PendingOutput(
            uri = uri,
            tempFile = temporaryFile,
            isPending = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q,
            isMediaStore = true,
        )
    }

    private fun publishOutput(output: PendingOutput) {
        if (!output.tempFile.isFile || output.tempFile.length() <= 0L) {
            throw IllegalStateException("CameraX 没有生成有效图片文件")
        }
        val target = contentResolver.openOutputStream(output.uri, "w")
            ?: throw IllegalStateException("无法打开 MediaStore 图片输出流")
        output.tempFile.inputStream().use { input ->
            target.use { outputStream -> input.copyTo(outputStream) }
        }
    }

    private fun finalizeOutput(output: PendingOutput) {
        if (!output.isPending) return
        val updated = contentResolver.update(
            output.uri,
            ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) },
            null,
            null,
        )
        if (updated <= 0) throw IllegalStateException("无法提交 MediaStore 图片")
    }

    private fun cleanupPendingOutput() {
        pendingOutput?.let { output ->
            runCatching { contentResolver.delete(output.uri, null, null) }
            runCatching { output.tempFile.delete() }
        }
        pendingOutput = null
    }

    private fun finishWith(result: JSONObject, callFinish: Boolean = true) {
        if (!completed.compareAndSet(false, true)) return
        if (result.has("error")) cleanupPendingOutput()
        unbindBoundUseCases()
        NativeCameraCaptureCapabilities.complete(requestId, result)
        runCatching {
            val resultIntent = Intent()
                .putExtra(NativeCameraCaptureCapabilities.EXTRA_REQUEST_ID, requestId)
                .putExtra(NativeCameraCaptureCapabilities.EXTRA_RESULT_JSON, result.toString())
            setResult(if (result.has("error")) Activity.RESULT_CANCELED else Activity.RESULT_OK, resultIntent)
        }
        if (callFinish) runCatching { finish() }
    }

    /** 只解绑本 Activity 创建的 CameraX use case，不干扰宿主其它相机页面。 */
    private fun unbindBoundUseCases() {
        val provider = cameraProvider ?: return
        boundPreview?.let { runCatching { provider.unbind(it) } }
        boundImageCapture?.let { runCatching { provider.unbind(it) } }
        boundPreview = null
        boundImageCapture = null
        imageCapture = null
    }

    private fun success(uri: Uri): JSONObject {
        val dimensions = readDimensions(uri)
        val result = JSONObject()
            .put("uri", uri.toString())
            .put("path", uri.toString())
            .put("webPath", uri.toString())
            .put("format", outputMimeType.substringAfter('/', "jpeg"))
            .put("width", dimensions.first)
            .put("height", dimensions.second)
            .put("saved", saveToGallery)
        if (resultType == "BASE64" || resultType == "DATA_URL") {
            val encoded = Base64.encodeToString(readImageBytes(uri), Base64.NO_WRAP)
            if (resultType == "BASE64") result.put("base64", encoded)
            if (resultType == "DATA_URL") result.put("dataUrl", "data:$outputMimeType;base64,$encoded")
        }
        return result
    }

    private fun readImageBytes(uri: Uri): ByteArray {
        val descriptorLength = runCatching {
            contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length }
        }.getOrNull() ?: -1L
        if (descriptorLength > MAX_INLINE_IMAGE_BYTES) {
            throw IllegalStateException("图片超过内联结果大小限制")
        }
        val bytes = contentResolver.openInputStream(uri)?.use { input ->
            val output = java.io.ByteArrayOutputStream(
                if (descriptorLength in 1..MAX_INLINE_IMAGE_BYTES) descriptorLength.toInt() else 16 * 1024,
            )
            val buffer = ByteArray(16 * 1024)
            var total = 0
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                total += count
                if (total > MAX_INLINE_IMAGE_BYTES) throw IllegalStateException("图片超过内联结果大小限制")
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        } ?: throw IllegalStateException("无法读取拍照图片")
        if (bytes.isEmpty()) throw IllegalStateException("拍照图片为空")
        return bytes
    }

    private fun readDimensions(uri: Uri): Pair<Int, Int> {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        val decoded = contentResolver.openInputStream(uri)?.use { stream ->
            BitmapFactory.decodeStream(stream, null, options)
        }
        if (decoded == null && (options.outWidth <= 0 || options.outHeight <= 0)) {
            throw IllegalStateException("无法读取拍照图片尺寸")
        }
        if (options.outWidth <= 0 || options.outHeight <= 0) {
            throw IllegalStateException("拍照结果不是可读取的图片")
        }
        return options.outWidth to options.outHeight
    }

    private fun error(code: String, message: String): JSONObject = JSONObject()
        .put("error", JSONObject().put("code", code).put("message", message))

    @Suppress("DEPRECATION")
    private fun isCameraPermissionDeclared(): Boolean = runCatching {
        packageManager.getPackageInfo(packageName, PackageManager.GET_PERMISSIONS)
            .requestedPermissions
            ?.contains(Manifest.permission.CAMERA) == true
    }.getOrDefault(false)

    private fun createContentView(): FrameLayout {
        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        val preview = PreviewView(this).apply {
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }
        previewView = preview
        root.addView(preview, FrameLayout.LayoutParams(-1, -1))

        val guidance = TextView(this).apply {
            text = "请将拍摄对象放入取景框"
            setTextColor(Color.WHITE)
            setBackgroundColor(0x99000000.toInt())
            setPadding(24, 18, 24, 18)
        }
        root.addView(guidance, FrameLayout.LayoutParams(-1, -2).apply {
            gravity = Gravity.TOP
        })

        val controls = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        val cancel = Button(this).apply {
            text = "取消"
            setOnClickListener { finishWith(error("CANCELLED", "用户取消了拍照")) }
        }
        val capture = Button(this).apply {
            text = "拍照"
            isEnabled = false
            setOnClickListener { capturePhoto() }
        }
        captureButton = capture
        controls.addView(cancel, LinearLayout.LayoutParams(0, -2, 1f).apply { marginEnd = 16 })
        controls.addView(capture, LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = 16 })
        root.addView(controls, FrameLayout.LayoutParams(-1, -2).apply {
            gravity = Gravity.BOTTOM
            leftMargin = 32
            rightMargin = 32
            bottomMargin = 32
        })
        return root
    }

    private data class PendingOutput(
        val uri: Uri,
        val tempFile: File,
        val isPending: Boolean,
        val isMediaStore: Boolean,
    )
}
