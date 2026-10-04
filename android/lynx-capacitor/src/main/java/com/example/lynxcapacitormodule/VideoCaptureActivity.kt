package com.example.lynxcapacitormodule

import android.Manifest
import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Bundle
import android.os.Build
import android.provider.MediaStore
import android.view.Gravity
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject

/** Camera.recordVideo 的自有 CameraX 页面；打开页面不等于录像成功，必须等待 Finalize。 */
class VideoCaptureActivity : AppCompatActivity() {
    private val completed = AtomicBoolean(false)

    private var requestId = ""
    private var owner: NativeOwnerScope? = null
    private var saveToGallery = false
    private var isPersistent = true
    private var includeMetadata = false
    private var includeMicrophone: Boolean? = null
    private var cameraOperationAcquired = false
    private var previewView: PreviewView? = null
    private var cameraProvider: ProcessCameraProvider? = null
    private var boundPreview: Preview? = null
    private var boundVideoCapture: VideoCapture<Recorder>? = null
    private var videoCapture: VideoCapture<Recorder>? = null
    private var recording: Recording? = null
    private var recordingFile: File? = null
    private var recordingStarted = false
    private var startButton: Button? = null
    private var stopButton: Button? = null
    private var statusView: TextView? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestId = intent.getStringExtra(NativeVideoCaptureCapabilities.EXTRA_REQUEST_ID).orEmpty()
        saveToGallery = intent.getBooleanExtra(NativeVideoCaptureCapabilities.EXTRA_SAVE_TO_GALLERY, false)
        isPersistent = intent.getBooleanExtra(NativeVideoCaptureCapabilities.EXTRA_IS_PERSISTENT, true)
        includeMetadata = intent.getBooleanExtra(NativeVideoCaptureCapabilities.EXTRA_INCLUDE_METADATA, false)
        includeMicrophone = if (intent.hasExtra(NativeVideoCaptureCapabilities.EXTRA_INCLUDE_MICROPHONE)) {
            intent.getBooleanExtra(NativeVideoCaptureCapabilities.EXTRA_INCLUDE_MICROPHONE, false)
        } else null
        if (requestId.isBlank()) {
            finishWith(error("INVALID_ARGUMENT", "录像 Activity 缺少 requestId"))
            return
        }

        owner = NativeVideoCaptureCapabilities.ownerForRequest(requestId)
        if (owner?.isActive != true) {
            finishWith(error("HOST_DESTROYED", "录像所属页面已销毁"))
            return
        }
        runCatching {
            setContentView(createContentView())
            onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() {
                    cancelRecording()
                }
            })
            ensureCameraPermissionAndStart()
        }.onFailure { throwable ->
            finishWith(error("UNAVAILABLE", throwable.message ?: "无法创建录像页面"))
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != CAMERA_PERMISSION_REQUEST_CODE) return
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) startCamera()
        else finishWith(error("PERMISSION_DENIED", "用户未授予相机权限"))
    }

    override fun onDestroy() {
        recording?.stop()
        recording = null
        if (!completed.get()) recordingFile?.delete()
        unbindBoundUseCases()
        if (cameraOperationAcquired) {
            NativeCameraXConfiguration.releaseOperation()
            cameraOperationAcquired = false
        }
        if (!isChangingConfigurations && !completed.get()) {
            finishWith(error("ACTIVITY_DESTROYED", "录像 Activity 已销毁"), callFinish = false)
        }
        super.onDestroy()
    }

    private fun ensureCameraPermissionAndStart() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
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
            val future = ProcessCameraProvider.getInstance(this)
            future.addListener({
                runCatching { future.get() }
                    .onSuccess(::bindCamera)
                    .onFailure { throwable -> finishWith(error("CAMERA_UNAVAILABLE", throwable.message ?: "无法获取 CameraX 相机")) }
            }, ContextCompat.getMainExecutor(this))
        }.onFailure { throwable ->
            finishWith(error("CAMERA_UNAVAILABLE", throwable.message ?: "无法初始化 CameraX"))
        }
    }

    private fun bindCamera(provider: ProcessCameraProvider) {
        if (completed.get() || isFinishing || isDestroyed) return
        val lensFacing = intent.getIntExtra(NativeVideoCaptureCapabilities.EXTRA_LENS_FACING, CameraSelector.LENS_FACING_BACK)
        val selector = CameraSelector.Builder().requireLensFacing(lensFacing).build()
        if (!runCatching { provider.hasCamera(selector) }.getOrDefault(false)) {
            finishWith(error("CAMERA_UNAVAILABLE", "设备没有可用的指定摄像头"))
            return
        }
        val preview = Preview.Builder().build().apply { setSurfaceProvider(previewView?.surfaceProvider) }
        val recorder = Recorder.Builder().build()
        val capture = VideoCapture.withOutput(recorder)
        runCatching {
            unbindBoundUseCases()
            provider.bindToLifecycle(this, selector, preview, capture)
            cameraProvider = provider
            boundPreview = preview
            boundVideoCapture = capture
            videoCapture = capture
            startButton?.isEnabled = true
            statusView?.text = "相机已准备，点击开始录像"
        }.onFailure { throwable ->
            finishWith(error("CAMERA_UNAVAILABLE", throwable.message ?: "无法绑定 CameraX 录像"))
        }
    }

    private fun startRecording() {
        if (completed.get() || recording != null) return
        if (owner?.isActive != true) { finishWith(error("HOST_DESTROYED", "录像所属页面已销毁")); return }
        val capture = videoCapture ?: run {
            finishWith(error("CAMERA_UNAVAILABLE", "录像相机尚未准备完成"))
            return
        }
        val microphoneGranted = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        if (includeMicrophone == true && !microphoneGranted) {
            finishWith(error("PERMISSION_DENIED", "有声录像需要麦克风权限"))
            return
        }
        val directory = if (isPersistent) filesDir else cacheDir
        val targetDirectory = File(directory, "lynx-video")
        if (!targetDirectory.exists() && !targetDirectory.mkdirs() && !targetDirectory.isDirectory) {
            finishWith(error("IO", "无法创建录像目录"))
            return
        }
        val file = File(targetDirectory, "recording-${System.currentTimeMillis()}-${UUID.randomUUID()}.mp4")
        val output = FileOutputOptions.Builder(file).setFileSizeLimit(NativePayloadBudget.DOWNLOAD_BYTES).build()
        var audioEnabled = false
        val pending = try {
            val prepared = capture.output.prepareRecording(this, output)
            // 显式 false 保持无声；缺省只沿用已授予麦克风权限时启用音轨的历史行为。
            if (includeMicrophone ?: microphoneGranted) prepared.withAudioEnabled().also { audioEnabled = true } else prepared
        } catch (failure: Exception) {
            file.delete()
            finishWith(error(if (failure is SecurityException) "PERMISSION_DENIED" else "RECORDING_FAILED",
                failure.message ?: "无法启用录像音轨"))
            return
        }
        recordingFile = file
        recordingStarted = true
        recording = pending.start(ContextCompat.getMainExecutor(this)) { event ->
            when (event) {
                is VideoRecordEvent.Start -> {
                    statusView?.text = if (audioEnabled) "录像中（含麦克风）" else "录像中（未启用麦克风）"
                    startButton?.isEnabled = false
                    stopButton?.isEnabled = true
                }
                is VideoRecordEvent.Finalize -> finalizeRecording(event, file, audioEnabled)
            }
        }
    }

    private fun stopRecording() {
        recording?.stop()
        stopButton?.isEnabled = false
        statusView?.text = "正在生成视频…"
    }

    private fun cancelRecording() {
        val active = recording
        if (active != null) {
            active.stop()
            recording = null
            recordingFile?.delete()
            finishWith(error("CANCELLED", "用户取消了录像"))
        } else {
            finishWith(error("CANCELLED", "用户取消了录像"))
        }
    }

    private fun finalizeRecording(event: VideoRecordEvent.Finalize, file: File, audioEnabled: Boolean) {
        recording = null
        if (completed.get()) {
            file.delete()
            return
        }
        if (event.error != VideoRecordEvent.Finalize.ERROR_NONE || !file.isFile || file.length() <= 0L) {
            file.delete()
            finishWith(error("RECORDING_FAILED", "CameraX 录像失败（${event.error}）"))
            return
        }
        NativeIO.local.submit(owner, { runOnUiThread { finishWith(error("BUSY", "录像结果执行队列已满")) } }) {
            try {
                NativePayloadBudget.check(file.length(), NativePayloadBudget.DOWNLOAD_BYTES)
                val sourceUri = if (saveToGallery) publishToGallery(file) else {
                    FileProvider.getUriForFile(this, NativeFileProviderContract.authority(this), file)
                }
                val result = mediaResult(sourceUri, file, audioEnabled)
                if (saveToGallery) file.delete()
                runOnUiThread {
                    if (owner?.isActive == true && !isDestroyed && !isFinishing) finishWith(result)
                }
            } catch (failure: Exception) {
                file.delete()
                runOnUiThread { finishWith(error(if (failure is NativeBudgetExceeded) failure.code else if (failure is NativeCallCancelled) "HOST_DESTROYED" else "IO",
                    failure.message ?: "无法保存录像结果")) }
            }
        }
    }

    private fun publishToGallery(file: File): Uri {
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, file.name)
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.Video.Media.RELATIVE_PATH, "Movies/LynxCamera")
                put(MediaStore.Video.Media.IS_PENDING, 1)
            }
        }
        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        }
        val uri = contentResolver.insert(collection, values) ?: throw IllegalStateException("无法创建 MediaStore 视频")
        try {
            contentResolver.openOutputStream(uri, "w")?.use { output -> file.inputStream().use { input -> NativePayloadBudget.copy(input, output, NativePayloadBudget.DOWNLOAD_BYTES) } }
                ?: throw IllegalStateException("无法写入 MediaStore 视频")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val updated = NativeCallContext.commit {
                    contentResolver.update(uri, ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }, null, null)
                }
                if (updated <= 0) throw IllegalStateException("无法提交 MediaStore 视频")
            }
            return uri
        } catch (throwable: Throwable) {
            runCatching { contentResolver.delete(uri, null, null) }
            throw throwable
        }
    }

    private fun mediaResult(uri: Uri, file: File, audioEnabled: Boolean): JSONObject {
        val metadata = MediaMetadataRetriever()
        val durationMs = runCatching {
            metadata.setDataSource(file.absolutePath)
            metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
        }.getOrNull()
        val width = runCatching { metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() }.getOrNull()
        val height = runCatching { metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() }.getOrNull()
        runCatching { metadata.release() }
        return JSONObject()
            .put("type", 1)
            .put("uri", uri.toString())
            .put("webPath", uri.toString())
            .put("saved", saveToGallery)
            .put("audioEnabled", audioEnabled)
            .apply {
                if (includeMetadata) {
                    put(
                        "metadata",
                        JSONObject()
                            .put("format", "mp4")
                            .put("size", file.length())
                            .apply {
                                durationMs?.let { put("duration", it / 1000.0) }
                                if (width != null && height != null) put("resolution", "${width}x${height}")
                            },
                    )
                }
            }
    }

    private fun finishWith(result: JSONObject, callFinish: Boolean = true) {
        if (!completed.compareAndSet(false, true)) return
        if (result.has("error")) recordingFile?.delete()
        unbindBoundUseCases()
        NativeVideoCaptureCapabilities.complete(requestId, result)
        runCatching {
            val resultIntent = Intent().putExtra(NativeVideoCaptureCapabilities.EXTRA_REQUEST_ID, requestId)
                .putExtra(NativeVideoCaptureCapabilities.EXTRA_RESULT_JSON, result.toString())
            setResult(if (result.has("error")) Activity.RESULT_CANCELED else Activity.RESULT_OK, resultIntent)
        }
        if (callFinish) runCatching { finish() }
    }

    private fun unbindBoundUseCases() {
        val provider = cameraProvider ?: return
        boundPreview?.let { runCatching { provider.unbind(it) } }
        boundVideoCapture?.let { runCatching { provider.unbind(it) } }
        boundPreview = null
        boundVideoCapture = null
        videoCapture = null
    }

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
        root.addView(guidance, FrameLayout.LayoutParams(-1, -2).apply { gravity = Gravity.TOP })
        statusView = TextView(this).apply {
            text = "正在准备相机…"
            setTextColor(Color.WHITE)
            setBackgroundColor(0x99000000.toInt())
            setPadding(24, 18, 24, 18)
        }
        root.addView(statusView, FrameLayout.LayoutParams(-1, -2).apply { gravity = Gravity.CENTER })
        val controls = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER }
        val cancel = Button(this).apply { text = "取消"; setOnClickListener { cancelRecording() } }
        val start = Button(this).apply { text = "开始录像"; isEnabled = false; setOnClickListener { startRecording() } }
        val stop = Button(this).apply { text = "停止录像"; isEnabled = false; setOnClickListener { stopRecording() } }
        startButton = start
        stopButton = stop
        controls.addView(cancel, LinearLayout.LayoutParams(0, -2, 1f).apply { marginEnd = 8 })
        controls.addView(start, LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = 8; marginEnd = 8 })
        controls.addView(stop, LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = 8 })
        root.addView(controls, FrameLayout.LayoutParams(-1, -2).apply { gravity = Gravity.BOTTOM; setMargins(24, 24, 24, 36) })
        return root
    }

    private fun error(code: String, message: String): JSONObject = JSONObject()
        .put("error", JSONObject().put("code", code).put("message", message))

    companion object {
        private const val CAMERA_PERMISSION_REQUEST_CODE = 49_101
    }
}
