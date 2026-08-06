package com.example.lynxshell.transition

import android.animation.ArgbEvaluator
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.view.View
import kotlin.math.roundToInt

/**
 * open-container 的双内容 clipped morph。
 *
 * 该 View 占满 transition overlay，但只绘制两层：
 * 1. outer shape：颜色、圆角与阴影；
 * 2. inner clip：关闭态源元素与打开态目标页面快照。
 *
 * 因为目标页面快照始终画在最终打开区域，并受动态圆角矩形 clip，所以 push 时目标内容
 * 只会在正在扩张的容器内部出现，不会在背后整页淡入。
 */
internal class LynxOpenContainerMorphView(
    context: Context,
    private val sourceBitmap: Bitmap,
    private val targetPageBitmap: Bitmap,
    private val sourceRect: Rect,
    private val targetRect: Rect,
    private val spec: LynxOpenContainerSpec,
    private val reverse: Boolean,
) : View(context) {
    private val density = resources.displayMetrics.density
    private val outerPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val bitmapPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val rect = RectF()
    private val clipPath = Path()
    private var progress = 0f

    init {
        // 软件层保证动态 shadow 在各 API/OEM 上可见；只存在于单次转场期间。
        setLayerType(LAYER_TYPE_SOFTWARE, null)
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
    }

    fun setTransitionProgress(value: Float) {
        progress = value.coerceIn(0f, 1f)
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val visualProgress = if (reverse) 1f - progress else progress
        val geometryProgress = if (reverse) 1f - progress else progress
        val current = interpolateRect(sourceRect, targetRect, geometryProgress)
        rect.set(current)

        val radius = lerp(
            spec.closedCornerRadius * density,
            spec.openCornerRadius * density,
            visualProgress,
        )
        val elevation = lerp(
            spec.closedElevation * density,
            spec.openElevation * density,
            visualProgress,
        )
        outerPaint.color = containerColor(visualProgress)
        if (elevation > 0.1f) {
            outerPaint.setShadowLayer(elevation * 0.75f, 0f, elevation * 0.24f, 0x55000000)
        } else {
            outerPaint.clearShadowLayer()
        }

        // outer shape：阴影不能放进 inner clip，否则会被裁掉。
        canvas.drawRoundRect(rect, radius, radius, outerPaint)

        val checkpoint = canvas.save()
        clipPath.reset()
        clipPath.addRoundRect(rect, radius, radius, Path.Direction.CW)
        canvas.clipPath(clipPath)
        canvas.drawColor(containerColor(visualProgress))

        val (sourceAlpha, targetAlpha) = contentAlphas(progress, reverse)
        if (targetAlpha > 0f) {
            bitmapPaint.alpha = (targetAlpha * 255).roundToInt().coerceIn(0, 255)
            canvas.drawBitmap(
                targetPageBitmap,
                null,
                RectF(targetRect),
                bitmapPaint,
            )
        }
        if (sourceAlpha > 0f) {
            bitmapPaint.alpha = (sourceAlpha * 255).roundToInt().coerceIn(0, 255)
            // 关闭态内容随容器尺寸缩放；反向时在收拢末段重新出现。
            canvas.drawBitmap(sourceBitmap, null, rect, bitmapPaint)
        }
        bitmapPaint.alpha = 255
        canvas.restoreToCount(checkpoint)
    }

    private fun contentAlphas(
        rawProgress: Float,
        isReverse: Boolean,
    ): Pair<Float, Float> {
        val p = rawProgress.coerceIn(0f, 1f)
        val forward = when (spec.transitionType) {
            LynxContainerContentTransition.FADE ->
                (1f - p) to p
            LynxContainerContentTransition.FADE_THROUGH -> {
                val outgoing = (1f - p / 0.35f).coerceIn(0f, 1f)
                val incoming = ((p - 0.35f) / 0.65f).coerceIn(0f, 1f)
                outgoing to incoming
            }
        }
        // forward 是 source -> target；pop 需要 target -> source。
        return if (isReverse) forward.second to forward.first else forward
    }

    private fun containerColor(visualProgress: Float): Int {
        val start = parseColor(spec.closedColor, Color.WHITE)
        val end = parseColor(spec.openColor, Color.WHITE)
        // Skyline 的 middleColor 只参与 fadeThrough；普通 fade 始终直接插值 closed/open。
        val middle = spec.middleColor
            ?.takeIf {
                spec.transitionType == LynxContainerContentTransition.FADE_THROUGH
            }
            ?.let { parseColor(it, Color.WHITE) }
        return if (middle != null) {
            if (visualProgress < 0.5f) {
                ArgbEvaluator().evaluate(visualProgress * 2f, start, middle) as Int
            } else {
                ArgbEvaluator().evaluate((visualProgress - 0.5f) * 2f, middle, end) as Int
            }
        } else {
            ArgbEvaluator().evaluate(visualProgress, start, end) as Int
        }
    }

    private fun interpolateRect(start: Rect, end: Rect, p: Float): RectF =
        RectF(
            lerp(start.left.toFloat(), end.left.toFloat(), p),
            lerp(start.top.toFloat(), end.top.toFloat(), p),
            lerp(start.right.toFloat(), end.right.toFloat(), p),
            lerp(start.bottom.toFloat(), end.bottom.toFloat(), p),
        )

    private fun lerp(start: Float, end: Float, p: Float): Float =
        start + (end - start) * p.coerceIn(0f, 1f)

    private fun parseColor(value: String?, fallback: Int): Int =
        LynxColorParser.parse(value, fallback)
}
