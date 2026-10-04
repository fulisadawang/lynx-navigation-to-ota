package com.example.lynxcapacitormodule

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.RectF
import android.media.ExifInterface
import android.os.Bundle
import android.view.GestureDetector
import android.view.Gravity
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.TextView
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AppCompatActivity
import org.json.JSONObject
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.min

/** 一次只解码当前图片；后台按窗口采样，切换时回收上一张，避免整组大图常驻内存。 */
class ImagePreviewActivity : AppCompatActivity() {
    private var requestId = ""
    private var session: NativeImagePreviewCapabilities.Session? = null
    private val renderOwner = NativeOwnerScope()
    private var image: PreviewImageView? = null
    private var status: TextView? = null
    private var bitmap: Bitmap? = null
    private var index = 0
    @Volatile private var generation = 0
    private var reportedReady = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestId = intent.getStringExtra(NativeImagePreviewCapabilities.EXTRA_REQUEST_ID).orEmpty()
        val session = NativeImagePreviewCapabilities.attach(requestId, this)
        if (session == null) { finish(); return }
        this.session = session
        index = (savedInstanceState?.getInt("imageIndex") ?: session.initialIndex).coerceIn(session.items.indices)
        val image = PreviewImageView(this) { delta -> changeImage(delta) }.also { this.image = it }
        val status = TextView(this).apply {
            setTextColor(Color.WHITE)
            setBackgroundColor(0x99000000.toInt())
            setPadding(24, 18, 24, 18)
        }.also { this.status = it }
        val close = TextView(this).apply {
            text = "关闭"
            contentDescription = "关闭图片预览"
            setTextColor(Color.WHITE)
            setPadding(24, 18, 24, 18)
            setOnClickListener { finish() }
        }
        setContentView(FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            addView(image, FrameLayout.LayoutParams(-1, -1))
            addView(status, FrameLayout.LayoutParams(-1, -2).apply { gravity = Gravity.TOP })
            addView(close, FrameLayout.LayoutParams(-2, -2).apply { gravity = Gravity.BOTTOM or Gravity.END })
            setOnApplyWindowInsetsListener { view, insets ->
                view.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop, insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
                insets.consumeSystemWindowInsets()
            }
        })
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() = finish()
        })
        image.post { loadImage() }
    }

    private fun changeImage(delta: Int) {
        val session = session ?: return
        if (!reportedReady) return
        val next = index + delta
        if (next !in session.items.indices) return
        index = next
        loadImage()
    }

    private fun loadImage() {
        val session = session ?: return
        if (session.owner?.isActive == false || isFinishing || isDestroyed) return
        val token = ++generation
        val targetWidth = (image?.width?.takeIf { it > 0 } ?: resources.displayMetrics.widthPixels).coerceIn(1, 2048)
        val targetHeight = (image?.height?.takeIf { it > 0 } ?: resources.displayMetrics.heightPixels).coerceIn(1, 2048)
        val selected = index
        status?.text = "${selected + 1}/${session.items.size} · 正在读取图片…"
        image?.setImageDrawable(null)
        bitmap?.recycle(); bitmap = null
        NativeIO.local.submit(renderOwner, { showFailure(token, "图片读取队列已满", "BUSY") }) {
            var decoded: Bitmap? = null
            try {
                if (token != generation || session.owner?.isActive == false) return@submit
                val media = session.items[selected]
                val uri = media.uri
                val orientation = if (media.mimeType == "image/jpeg") {
                    requireNotNull(contentResolver.openInputStream(uri)) { "图片不可读取" }.use {
                        ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
                    }
                } else ExifInterface.ORIENTATION_NORMAL
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                requireNotNull(contentResolver.openInputStream(uri)) { "图片不可读取" }.use { BitmapFactory.decodeStream(it, null, bounds) }
                require(bounds.outWidth > 0 && bounds.outHeight > 0) { "所选文件不是可解码图片" }
                val rotated = orientation in setOf(ExifInterface.ORIENTATION_TRANSPOSE, ExifInterface.ORIENTATION_ROTATE_90,
                    ExifInterface.ORIENTATION_TRANSVERSE, ExifInterface.ORIENTATION_ROTATE_270)
                val orientedWidth = if (rotated) bounds.outHeight else bounds.outWidth
                val orientedHeight = if (rotated) bounds.outWidth else bounds.outHeight
                var sample = 1
                // 文件读取都在有界 IO 队列；解码像素最多约 4M，避免全尺寸相册照片占满堆。
                while (ceil(orientedWidth.toDouble() / sample) > targetWidth ||
                    ceil(orientedHeight.toDouble() / sample) > targetHeight) {
                    sample = if (sample > Int.MAX_VALUE / 2) Int.MAX_VALUE else sample * 2
                }
                NativeCallContext.checkActive()
                if (token != generation || session.owner?.isActive == false) return@submit
                val options = BitmapFactory.Options().apply { inSampleSize = sample; inPreferredConfig = Bitmap.Config.ARGB_8888 }
                decoded = requireNotNull(contentResolver.openInputStream(uri)) { "图片不可读取" }.use { BitmapFactory.decodeStream(it, null, options) }
                require(decoded != null) { "图片解码失败" }
                val output = requireNotNull(decoded)
                decoded = null
                runOnUiThread {
                    if (token != generation || isDestroyed || isFinishing || session.owner?.isActive == false) { output.recycle(); return@runOnUiThread }
                    bitmap = output
                    image?.display(output, orientation)
                    status?.text = "${selected + 1}/${session.items.size} · 左右滑动切换，双指缩放"
                    if (!reportedReady) { reportedReady = true; NativeImagePreviewCapabilities.ready(requestId) }
                }
            } catch (_: OutOfMemoryError) {
                decoded?.recycle()
                showFailure(token, "当前设备内存不足，无法解码图片", "IMAGE_DECODE_FAILED")
            } catch (failure: Exception) {
                decoded?.recycle()
                if (failure !is NativeCallCancelled) showFailure(token, failure.message ?: "图片读取失败", "IMAGE_READ_FAILED")
            }
        }
    }

    private fun showFailure(token: Int, message: String, code: String) {
        runOnUiThread {
            if (token != generation || isDestroyed || isFinishing) return@runOnUiThread
            status?.text = "${index + 1}/${session?.items?.size ?: 0} · $message"
            if (!reportedReady) {
                NativeImagePreviewCapabilities.finish(requestId, JSONObject().put("error", JSONObject().put("code", code).put("message", message)))
                finish()
            }
        }
    }
    override fun onSaveInstanceState(outState: Bundle) { outState.putInt("imageIndex", index); super.onSaveInstanceState(outState) }
    override fun onDestroy() {
        generation++
        renderOwner.end()
        image?.setImageDrawable(null)
        bitmap?.recycle(); bitmap = null
        image = null; status = null
        if (!isChangingConfigurations) NativeImagePreviewCapabilities.finish(requestId)
        super.onDestroy()
    }

    private class PreviewImageView(activity: AppCompatActivity, private val switch: (Int) -> Unit) : ImageView(activity) {
        private val transform = Matrix()
        private var zoom = 1f
        private var orientation = ExifInterface.ORIENTATION_NORMAL
        private var previousX = 0f
        private var previousY = 0f
        private var swipeStartX = 0f
        private var swipeStartY = 0f
        private var pagingEligible = false
        private var pageChanged = false
        private val scale = ScaleGestureDetector(activity, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScale(detector: ScaleGestureDetector): Boolean {
                val next = (zoom * detector.scaleFactor).coerceIn(1f, 4f)
                transform.postScale(next / zoom, next / zoom, detector.focusX, detector.focusY)
                zoom = next
                imageMatrix = transform
                return true
            }
        })
        private val gesture = GestureDetector(activity, object : GestureDetector.SimpleOnGestureListener() {
            override fun onDown(event: MotionEvent): Boolean = true
            override fun onFling(first: MotionEvent?, second: MotionEvent, velocityX: Float, velocityY: Float): Boolean {
                if (first == null || !pagingEligible || zoom > 1.01f || scale.isInProgress) return false
                val dx = second.x - first.x
                if (abs(dx) < width * .15f || abs(dx) <= abs(second.y - first.y) || abs(velocityX) < 150f) return false
                pageChanged = true
                switch(if (dx < 0) 1 else -1)
                return true
            }
            override fun onDoubleTap(event: MotionEvent): Boolean { fit(); return true }
        })
        init { scaleType = ScaleType.MATRIX; contentDescription = "原生图片预览，左右滑动切换，双指缩放" }
        fun display(bitmap: Bitmap, orientation: Int) { this.orientation = orientation; setImageBitmap(bitmap); fit() }
        private fun fit() {
            val current = drawable ?: return
            if (width == 0 || height == 0 || current.intrinsicWidth <= 0 || current.intrinsicHeight <= 0) return
            transform.reset()
            // BitmapFactory 不应用 EXIF；矩阵负责方向和镜像，避免再分配一个旋转 Bitmap。
            when (orientation) {
                ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> transform.setScale(-1f, 1f)
                ExifInterface.ORIENTATION_ROTATE_180 -> transform.setRotate(180f)
                ExifInterface.ORIENTATION_FLIP_VERTICAL -> transform.setScale(1f, -1f)
                ExifInterface.ORIENTATION_TRANSPOSE -> transform.setValues(floatArrayOf(0f, 1f, 0f, 1f, 0f, 0f, 0f, 0f, 1f))
                ExifInterface.ORIENTATION_ROTATE_90 -> transform.setRotate(90f)
                ExifInterface.ORIENTATION_TRANSVERSE -> transform.setValues(floatArrayOf(0f, -1f, 0f, -1f, 0f, 0f, 0f, 0f, 1f))
                ExifInterface.ORIENTATION_ROTATE_270 -> transform.setRotate(270f)
            }
            val bounds = RectF(0f, 0f, current.intrinsicWidth.toFloat(), current.intrinsicHeight.toFloat())
            transform.mapRect(bounds)
            val factor = min(width / bounds.width(), height / bounds.height())
            transform.postTranslate(-bounds.left, -bounds.top)
            transform.postScale(factor, factor)
            transform.postTranslate((width - bounds.width() * factor) / 2, (height - bounds.height() * factor) / 2)
            zoom = 1f
            imageMatrix = transform
        }
        override fun onSizeChanged(width: Int, height: Int, oldWidth: Int, oldHeight: Int) { super.onSizeChanged(width, height, oldWidth, oldHeight); fit() }
        override fun onTouchEvent(event: MotionEvent): Boolean {
            if (event.actionMasked == MotionEvent.ACTION_DOWN) {
                swipeStartX = event.x; swipeStartY = event.y
                pagingEligible = zoom <= 1.01f
                pageChanged = false
            } else if (event.actionMasked == MotionEvent.ACTION_POINTER_DOWN || event.actionMasked == MotionEvent.ACTION_CANCEL) {
                pagingEligible = false
            }
            scale.onTouchEvent(event)
            gesture.onTouchEvent(event)
            if (event.actionMasked == MotionEvent.ACTION_DOWN) { previousX = event.x; previousY = event.y }
            if (event.actionMasked == MotionEvent.ACTION_MOVE && zoom > 1.01f && !scale.isInProgress && event.pointerCount == 1) {
                transform.postTranslate(event.x - previousX, event.y - previousY)
                imageMatrix = transform
            }
            previousX = event.x; previousY = event.y
            if (event.actionMasked == MotionEvent.ACTION_UP) {
                // 慢拖也按位移切页；快速划动已经处理时不重复翻页，缩放手势不触发切页。
                val dx = event.x - swipeStartX
                if (pagingEligible && !pageChanged && zoom <= 1.01f && !scale.isInProgress &&
                    abs(dx) >= width * .15f && abs(dx) > abs(event.y - swipeStartY)) {
                    switch(if (dx < 0) 1 else -1)
                }
                performClick()
            }
            return true
        }
        override fun performClick(): Boolean { super.performClick(); return true }
    }
}
