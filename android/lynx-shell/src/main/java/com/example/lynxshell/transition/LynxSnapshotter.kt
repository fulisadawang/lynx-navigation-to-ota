package com.example.lynxshell.transition

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import android.view.View
import java.util.concurrent.atomic.AtomicBoolean

/** Window 快照只在导航点击时生成一次；手势 progress 阶段绝不再分配 Bitmap。 */
object LynxSnapshotter {
    private const val DEFAULT_TIMEOUT_MS = 120L
    private val mainHandler = Handler(Looper.getMainLooper())

    fun captureWindow(
        activity: Activity,
        timeoutMs: Long = DEFAULT_TIMEOUT_MS,
        callback: (Result<Bitmap>) -> Unit,
    ) {
        check(Looper.myLooper() == Looper.getMainLooper()) { "Window 快照必须从主线程发起" }
        val decor = activity.window.decorView
        val width = decor.width
        val height = decor.height
        if (width <= 0 || height <= 0 || !decor.isAttachedToWindow) {
            callback(Result.failure(IllegalStateException("Window 尚未完成布局")))
            return
        }

        val bitmap = runCatching {
            Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        }.getOrElse {
            callback(Result.failure(it))
            return
        }

        if (Build.VERSION.SDK_INT < 26) {
            callback(
                runCatching {
                    Canvas(bitmap).also { canvas -> decor.draw(canvas) }
                    bitmap
                },
            )
            return
        }

        val completed = AtomicBoolean(false)
        val timeout = Runnable {
            if (completed.compareAndSet(false, true)) {
                callback(Result.failure(IllegalStateException("Window PixelCopy 超时")))
            }
        }
        mainHandler.postDelayed(timeout, timeoutMs)
        try {
            PixelCopy.request(
                activity.window,
                bitmap,
                { copyResult ->
                    if (!completed.compareAndSet(false, true)) return@request
                    mainHandler.removeCallbacks(timeout)
                    if (copyResult == PixelCopy.SUCCESS) {
                        callback(Result.success(bitmap))
                    } else {
                        callback(
                            Result.failure(
                                IllegalStateException("Window PixelCopy 失败: $copyResult"),
                            ),
                        )
                    }
                },
                mainHandler,
            )
        } catch (error: Throwable) {
            mainHandler.removeCallbacks(timeout)
            if (completed.compareAndSet(false, true)) callback(Result.failure(error))
        }
    }

    /**
     * source rect 使用屏幕坐标；裁剪前需扣掉 Window decor 的屏幕起点并 clamp。
     */
    fun cropWindowBitmap(
        activity: Activity,
        windowBitmap: Bitmap,
        rectOnScreen: Rect,
    ): Bitmap? {
        val location = IntArray(2)
        activity.window.decorView.getLocationOnScreen(location)
        val local = Rect(rectOnScreen).apply { offset(-location[0], -location[1]) }
        val bounds = Rect(0, 0, windowBitmap.width, windowBitmap.height)
        if (!local.intersect(bounds) || local.isEmpty) return null
        return runCatching {
            Bitmap.createBitmap(
                windowBitmap,
                local.left,
                local.top,
                local.width(),
                local.height(),
            )
        }.getOrNull()
    }

    /**
     * 把已经单独裁出的源元素从 Window underlay 隐去。
     *
     * 不能使用 PorterDuff.CLEAR 留透明洞：目标 Activity 首帧与 overlay 首帧之间存在
     * 一个很短的 Window 交接区间，透明洞会直接透出主题默认色，真机上表现为醒目的白块。
     * 这里从元素上边缘外侧采样原页面背景并回填；动画 proxy/morph 随后覆盖起点，既避免
     * 双影，也不会在 Activity 交接时闪出白色矩形。
     */
    fun clearWindowRects(
        activity: Activity,
        windowBitmap: Bitmap,
        rectsOnScreen: List<Rect>,
    ): Boolean {
        if (rectsOnScreen.isEmpty()) return true
        if (!windowBitmap.isMutable || windowBitmap.isRecycled) return false
        val location = IntArray(2)
        activity.window.decorView.getLocationOnScreen(location)
        return runCatching {
            val canvas = Canvas(windowBitmap)
            val backdropPaint = Paint().apply { style = Paint.Style.FILL }
            val bounds = Rect(0, 0, windowBitmap.width, windowBitmap.height)
            rectsOnScreen.forEach { screenRect ->
                val local = Rect(screenRect).apply {
                    offset(-location[0], -location[1])
                }
                if (local.intersect(bounds) && !local.isEmpty) {
                    backdropPaint.color = sampleBackdropColor(windowBitmap, local)
                    canvas.drawRect(local, backdropPaint)
                }
            }
            true
        }.getOrDefault(false)
    }

    /** 优先采样元素上方；贴顶元素再依次使用左、右、下方像素。 */
    private fun sampleBackdropColor(bitmap: Bitmap, rect: Rect): Int {
        val centerX = rect.centerX().coerceIn(0, bitmap.width - 1)
        val centerY = rect.centerY().coerceIn(0, bitmap.height - 1)
        return when {
            rect.top > 0 -> bitmap.getPixel(centerX, rect.top - 1)
            rect.left > 0 -> bitmap.getPixel(rect.left - 1, centerY)
            rect.right < bitmap.width -> bitmap.getPixel(rect.right, centerY)
            rect.bottom < bitmap.height -> bitmap.getPixel(centerX, rect.bottom)
            else -> bitmap.getPixel(centerX, centerY)
        }
    }

    /**
     * 目标页首屏已经由 Lynx 回调确认后，直接冻结当前 View。
     *
     * 该方法只在转场开始/返回开始时执行一次，动画帧内只重绘 Bitmap。若 Lynx 内部使用
     * Surface 等无法被 View.draw 捕获的实现，调用方会明确降级，不伪造成功。
     */
    fun captureViewBitmap(view: View): Bitmap? {
        check(Looper.myLooper() == Looper.getMainLooper()) { "View 快照必须从主线程生成" }
        if (
            view.width <= 0 ||
            view.height <= 0 ||
            !view.isAttachedToWindow
        ) {
            return null
        }
        /*
         * shared/open-container 在等待目标首帧时会把 liveContent.alpha 设为 0，避免
         * 真实目标页抢先露出。直接调用 alpha=0 View.draw() 在部分 Android 实现上只会
         * 得到主题背景（真机表现为一张白图），随后 morph 就变成“白块扩到全屏”。
         *
         * 同一主线程调用栈内临时恢复 alpha，只影响离屏 Canvas；在下一次 vsync 前立即
         * 还原，因此屏幕上不会泄漏目标终态。
         */
        val originalAlpha = view.alpha
        return try {
            view.alpha = 1f
            runCatching {
                Bitmap.createBitmap(
                    view.width,
                    view.height,
                    Bitmap.Config.ARGB_8888,
                ).also { bitmap ->
                    Canvas(bitmap).also { canvas -> view.draw(canvas) }
                }
            }.getOrNull()
        } finally {
            view.alpha = originalAlpha
        }
    }
}
