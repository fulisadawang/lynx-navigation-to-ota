package com.example.lynxcapacitormodule

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.widget.Button
import android.widget.FrameLayout
import android.widget.TextView
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONArray
import org.json.JSONObject

/**
 * 自有 Android 条码扫描页面：CameraX 提供预览和帧分析，ML Kit 负责条码识别。
 *
 * 该 Activity 不依赖 Capacitor runtime/plugin。所有失败路径都转换为结构化 error，并通过
 * NativeBarcodeCapabilities 的进程内 pending store 一次性回调给主 runtime。
 */
class BarcodeScanActivity : AppCompatActivity() {
    private companion object {
        const val CAMERA_PERMISSION_REQUEST_CODE = 48_001
    }

    private val completed = AtomicBoolean(false)
    private val analyzing = AtomicBoolean(false)
    private val cameraExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    private var requestId: String = ""
    private var hint: Int = 17
    private var lensFacing: Int = CameraSelector.LENS_FACING_BACK
    private var scanInstructions: String = ""
    private var ignoredOptions = JSONArray()
    private var previewView: PreviewView? = null
    private var cameraProvider: ProcessCameraProvider? = null
    private var barcodeScanner: BarcodeScanner? = null
    private var boundPreview: Preview? = null
    private var boundAnalysis: ImageAnalysis? = null
    private var cameraOperationAcquired = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestId = intent.getStringExtra(NativeBarcodeCapabilities.EXTRA_REQUEST_ID).orEmpty()
        hint = intent.getIntExtra(NativeBarcodeCapabilities.EXTRA_HINT, 17)
        lensFacing = intent.getIntExtra(
            NativeBarcodeCapabilities.EXTRA_LENS_FACING,
            CameraSelector.LENS_FACING_BACK,
        )
        scanInstructions = intent.getStringExtra(NativeBarcodeCapabilities.EXTRA_SCAN_INSTRUCTIONS).orEmpty()
        ignoredOptions = parseIgnoredOptions(
            intent.getStringExtra(NativeBarcodeCapabilities.EXTRA_IGNORED_OPTIONS),
        )

        if (requestId.isBlank()) {
            finishWith(error("INVALID_ARGUMENT", "扫码 Activity 缺少 requestId"))
            return
        }

        runCatching {
            setContentView(createContentView())
            onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() {
                    finishWith(error("CANCELLED", "用户取消了条码扫描"))
                }
            })
            ensureCameraPermissionAndStart()
        }.onFailure { throwable ->
            finishWith(error("UNAVAILABLE", throwable.message ?: "无法创建条码扫描界面"))
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
        runCatching { barcodeScanner?.close() }
        cameraExecutor.shutdown()
        // 配置变更会销毁旧 Activity 并重建新 Activity，不能在这种正常重建路径消费 pending callback。
        if (!isChangingConfigurations && !completed.get()) {
            finishWith(error("ACTIVITY_DESTROYED", "扫码 Activity 已销毁"), callFinish = false)
        }
        super.onDestroy()
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
        val formats = mlKitFormatsForHint(hint)
        val scannerOptions = BarcodeScannerOptions.Builder().apply {
            if (formats != null) setBarcodeFormats(formats.first(), *formats.drop(1).toIntArray())
        }.build()
        barcodeScanner = runCatching { BarcodeScanning.getClient(scannerOptions) }.getOrElse { throwable ->
            finishWith(error("UNAVAILABLE", throwable.message ?: "无法创建 ML Kit 条码扫描器"))
            return
        }

        runCatching {
            val providerFuture = ProcessCameraProvider.getInstance(this)
            providerFuture.addListener({
                runCatching { providerFuture.get() }
                    .onSuccess { bindCamera(it) }
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

        val preview = Preview.Builder().build()
        val analysis = ImageAnalysis.Builder()
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .build()
        preview.setSurfaceProvider(previewView?.surfaceProvider)
        analysis.setAnalyzer(cameraExecutor) { imageProxy -> analyze(imageProxy) }

        runCatching {
            unbindBoundUseCases()
            provider.bindToLifecycle(this, selector, preview, analysis)
            cameraProvider = provider
            boundPreview = preview
            boundAnalysis = analysis
        }.onFailure { throwable ->
            finishWith(error("CAMERA_UNAVAILABLE", throwable.message ?: "无法绑定 CameraX 预览"))
        }
    }

    private fun analyze(imageProxy: ImageProxy) {
        if (completed.get() || !analyzing.compareAndSet(false, true)) {
            imageProxy.close()
            return
        }
        val mediaImage = imageProxy.image
        if (mediaImage == null) {
            analyzing.set(false)
            imageProxy.close()
            return
        }

        val image = runCatching {
            InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)
        }.getOrElse { throwable ->
            analyzing.set(false)
            imageProxy.close()
            finishWith(error("SCAN_FAILED", throwable.message ?: "无法读取相机帧"))
            return
        }

        barcodeScanner?.process(image)
            ?.addOnSuccessListener { barcodes ->
                val barcode = barcodes.firstOrNull { !it.rawValue.isNullOrBlank() }
                if (barcode != null) finishWith(success(barcode))
            }
            ?.addOnFailureListener { throwable ->
                finishWith(error("SCAN_FAILED", throwable.message ?: "ML Kit 条码识别失败"))
            }
            ?.addOnCompleteListener {
                analyzing.set(false)
                imageProxy.close()
            }
            ?: run {
                analyzing.set(false)
                imageProxy.close()
                finishWith(error("SCAN_FAILED", "ML Kit 条码扫描器不可用"))
            }
    }

    private fun success(barcode: Barcode): JSONObject {
        val rawValue = barcode.rawValue.orEmpty()
        val result = JSONObject()
            // ScanResult 是现有跨端契约字段；rawValue/scanResult 是 Android 原始值别名。
            .put("ScanResult", rawValue)
            .put("scanResult", rawValue)
            .put("rawValue", rawValue)
            .put("format", capacitorHintForFormat(barcode.format))
            .put("formatName", formatName(barcode.format))
            .put("mlKitFormat", barcode.format)
            .put("valueType", barcode.valueType)
            .put("cameraDirection", if (lensFacing == CameraSelector.LENS_FACING_FRONT) "FRONT" else "BACK")
        barcode.displayValue?.let { result.put("displayValue", it) }
        if (ignoredOptions.length() > 0) result.put("ignoredOptions", ignoredOptions)
        return result
    }

    private fun finishWith(result: JSONObject, callFinish: Boolean = true) {
        if (!completed.compareAndSet(false, true)) return
        unbindBoundUseCases()
        NativeBarcodeCapabilities.complete(requestId, result)
        runCatching {
            val intent = Intent().putExtra(
                NativeBarcodeCapabilities.EXTRA_REQUEST_ID,
                requestId,
            ).putExtra(
                NativeBarcodeCapabilities.EXTRA_RESULT_JSON,
                result.toString(),
            )
            setResult(if (result.has("error")) Activity.RESULT_CANCELED else Activity.RESULT_OK, intent)
        }
        if (callFinish) runCatching { finish() }
    }

    /** 只解绑本 Activity 创建的 CameraX use case，不影响宿主其它相机页面。 */
    private fun unbindBoundUseCases() {
        val provider = cameraProvider ?: return
        boundPreview?.let { runCatching { provider.unbind(it) } }
        boundAnalysis?.let { runCatching { provider.unbind(it) } }
        boundPreview = null
        boundAnalysis = null
    }

    private fun createContentView(): FrameLayout {
        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        val preview = PreviewView(this).apply {
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }
        previewView = preview
        root.addView(preview, FrameLayout.LayoutParams(-1, -1))

        val instruction = TextView(this).apply {
            text = scanInstructions.ifBlank { "将条码放入取景框内" }
            setTextColor(Color.WHITE)
            setBackgroundColor(0x99000000.toInt())
            setPadding(24, 18, 24, 18)
        }
        root.addView(instruction, FrameLayout.LayoutParams(-1, -2).apply {
            gravity = Gravity.TOP
        })

        val cancel = Button(this).apply {
            text = "取消"
            setOnClickListener { finishWith(error("CANCELLED", "用户取消了条码扫描")) }
        }
        root.addView(cancel, FrameLayout.LayoutParams(-2, -2).apply {
            gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
            bottomMargin = 32
        })
        return root
    }

    @Suppress("DEPRECATION")
    private fun isCameraPermissionDeclared(): Boolean = runCatching {
        packageManager.getPackageInfo(packageName, PackageManager.GET_PERMISSIONS)
            .requestedPermissions
            ?.contains(Manifest.permission.CAMERA) == true
    }.getOrDefault(false)

    private fun parseIgnoredOptions(raw: String?): JSONArray = runCatching {
        raw?.let(::JSONArray) ?: JSONArray()
    }.getOrElse { JSONArray() }

    private fun mlKitFormatsForHint(hint: Int): IntArray? = when (hint) {
        0 -> intArrayOf(Barcode.FORMAT_QR_CODE)
        1 -> intArrayOf(Barcode.FORMAT_AZTEC)
        2 -> intArrayOf(Barcode.FORMAT_CODABAR)
        3 -> intArrayOf(Barcode.FORMAT_CODE_39)
        4 -> intArrayOf(Barcode.FORMAT_CODE_93)
        5 -> intArrayOf(Barcode.FORMAT_CODE_128)
        6 -> intArrayOf(Barcode.FORMAT_DATA_MATRIX)
        8 -> intArrayOf(Barcode.FORMAT_ITF)
        9 -> intArrayOf(Barcode.FORMAT_EAN_13)
        10 -> intArrayOf(Barcode.FORMAT_EAN_8)
        11 -> intArrayOf(Barcode.FORMAT_PDF417)
        14 -> intArrayOf(Barcode.FORMAT_UPC_A)
        15 -> intArrayOf(Barcode.FORMAT_UPC_E)
        17 -> null
        else -> intArrayOf()
    }

    private fun capacitorHintForFormat(format: Int): Int = when (format) {
        Barcode.FORMAT_QR_CODE -> 0
        Barcode.FORMAT_AZTEC -> 1
        Barcode.FORMAT_CODABAR -> 2
        Barcode.FORMAT_CODE_39 -> 3
        Barcode.FORMAT_CODE_93 -> 4
        Barcode.FORMAT_CODE_128 -> 5
        Barcode.FORMAT_DATA_MATRIX -> 6
        Barcode.FORMAT_ITF -> 8
        Barcode.FORMAT_EAN_13 -> 9
        Barcode.FORMAT_EAN_8 -> 10
        Barcode.FORMAT_PDF417 -> 11
        Barcode.FORMAT_UPC_A -> 14
        Barcode.FORMAT_UPC_E -> 15
        else -> -1
    }

    private fun formatName(format: Int): String = when (format) {
        Barcode.FORMAT_QR_CODE -> "QR_CODE"
        Barcode.FORMAT_AZTEC -> "AZTEC"
        Barcode.FORMAT_CODABAR -> "CODABAR"
        Barcode.FORMAT_CODE_39 -> "CODE_39"
        Barcode.FORMAT_CODE_93 -> "CODE_93"
        Barcode.FORMAT_CODE_128 -> "CODE_128"
        Barcode.FORMAT_DATA_MATRIX -> "DATA_MATRIX"
        Barcode.FORMAT_ITF -> "ITF"
        Barcode.FORMAT_EAN_13 -> "EAN_13"
        Barcode.FORMAT_EAN_8 -> "EAN_8"
        Barcode.FORMAT_PDF417 -> "PDF_417"
        Barcode.FORMAT_UPC_A -> "UPC_A"
        Barcode.FORMAT_UPC_E -> "UPC_E"
        else -> "UNKNOWN"
    }

    private fun error(code: String, message: String): JSONObject = JSONObject()
        .put("error", JSONObject().put("code", code).put("message", message))
}
