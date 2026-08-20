package com.example.lynxshell.transition

import android.content.Context
import android.graphics.Rect
import android.os.Build
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.widget.FrameLayout
import kotlin.math.abs

interface LynxCompatEdgeGestureDelegate {
    fun onCompatEdgeStart(): Boolean
    fun onCompatEdgeProgress(progress: Float)
    fun onCompatEdgeDelta(deltaPx: Float) {}
    fun onCompatEdgeCancel()
    fun onCompatEdgeFinish(velocityPxPerSecond: Float)
}

/**
 * API 24-33 的窄边缘返回兼容层。
 *
 * Android 14 以下系统不提供 BackEvent progress，因此由该布局补齐 horizontal /
 * vertical / multi。默认只从 edgeWidth 起手；fullscreenDrag=true 时才允许全屏起手。
 */
class LynxCompatEdgeBackLayout @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : FrameLayout(context, attrs) {
    private enum class GestureAxis {
        UNDECIDED,
        HORIZONTAL,
        VERTICAL,
    }

    var gestureDelegate: LynxCompatEdgeGestureDelegate? = null
    var compatGestureEnabled: Boolean = false
        set(value) {
            field = value
            updateGestureExclusion()
        }
    var edgeWidthDp: Float = 28f
        set(value) {
            field = value.coerceIn(16f, 72f)
            updateGestureExclusion()
        }
    var gestureDirection: LynxPopGestureDirection = LynxPopGestureDirection.HORIZONTAL
        set(value) {
            field = value
            updateGestureExclusion()
        }
    var fullScreenGesture: Boolean = false
        set(value) {
            field = value
            updateGestureExclusion()
        }
    /** bottom-sheet 纵向拖拽按可见 Sheet 高度归一化；null 时沿用完整容器尺寸。 */
    var verticalGestureExtentPx: Float? = null
        set(value) {
            field = value?.takeIf { it > 0f }
        }
    /** 多档位 heroSheet 允许向上展开；普通返回手势仍只接受向后方向。 */
    var verticalSheetDragEnabled: Boolean = false
        set(value) {
            field = value
            updateGestureExclusion()
        }

    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private var downX = 0f
    private var downY = 0f
    private var activePointerID = MotionEvent.INVALID_POINTER_ID
    private var possible = false
    private var dragging = false
    private var activeAxis = GestureAxis.UNDECIDED
    private var velocityTracker: VelocityTracker? = null

    override fun onInterceptTouchEvent(event: MotionEvent): Boolean {
        if (!canHandleCompatGesture()) return super.onInterceptTouchEvent(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                resetGesture()
                downX = event.x
                downY = event.y
                activePointerID = event.getPointerId(0)
                activeAxis = when (gestureDirection) {
                    LynxPopGestureDirection.HORIZONTAL -> GestureAxis.HORIZONTAL
                    LynxPopGestureDirection.VERTICAL -> GestureAxis.VERTICAL
                    LynxPopGestureDirection.MULTI -> GestureAxis.UNDECIDED
                }
                possible = isInsideStartRegion(event.x, event.y)
                if (possible) {
                    velocityTracker = VelocityTracker.obtain().also { it.addMovement(event) }
                }
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                if (possible) cancelBeforeDrag()
            }
            MotionEvent.ACTION_MOVE -> {
                if (!possible || activePointerID == MotionEvent.INVALID_POINTER_ID) return false
                velocityTracker?.addMovement(event)
                val index = event.findPointerIndex(activePointerID)
                if (index < 0) {
                    cancelBeforeDrag()
                    return false
                }
                val rawDx = forwardHorizontalDistance(event.getX(index))
                val rawDy = forwardVerticalDistance(event.getY(index))
                val absDx = abs(rawDx)
                val absDy = abs(rawDy)
                if (activeAxis == GestureAxis.UNDECIDED) {
                    activeAxis = when {
                        verticalSheetDragEnabled &&
                            absDy > touchSlop &&
                            absDy > absDx * 1.2f ->
                            GestureAxis.VERTICAL
                        rawDx > touchSlop && absDx > absDy * 1.2f ->
                            GestureAxis.HORIZONTAL
                        rawDy > touchSlop && absDy > absDx * 1.2f ->
                            GestureAxis.VERTICAL
                        absDx > touchSlop && rawDx < 0f -> {
                            cancelBeforeDrag()
                            return false
                        }
                        absDy > touchSlop && rawDy < 0f -> {
                            cancelBeforeDrag()
                            return false
                        }
                        else -> GestureAxis.UNDECIDED
                    }
                }
                val forward = if (activeAxis == GestureAxis.VERTICAL) {
                    if (verticalSheetDragEnabled) abs(rawDy) else rawDy
                } else {
                    rawDx
                }
                val cross = if (activeAxis == GestureAxis.VERTICAL) absDx else absDy
                if (
                    activeAxis != GestureAxis.UNDECIDED &&
                    forward > touchSlop &&
                    forward > cross * 1.2f
                ) {
                    dragging = gestureDelegate?.onCompatEdgeStart() == true
                    possible = dragging
                    if (dragging) {
                        parent?.requestDisallowInterceptTouchEvent(true)
                        return true
                    }
                } else if (
                    activeAxis != GestureAxis.UNDECIDED &&
                    cross > touchSlop &&
                    cross > abs(forward)
                ) {
                    cancelBeforeDrag()
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> resetGesture()
        }
        return dragging
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!dragging) return super.onTouchEvent(event)
        velocityTracker?.addMovement(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_MOVE -> {
                val index = event.findPointerIndex(activePointerID)
                if (index < 0) {
                    finishGesture(commit = false)
                    return true
                }
                val coordinate = if (activeAxis == GestureAxis.VERTICAL) {
                    event.getY(index)
                } else {
                    event.getX(index)
                }
                if (activeAxis == GestureAxis.VERTICAL && verticalSheetDragEnabled) {
                    gestureDelegate?.onCompatEdgeDelta(
                        forwardVerticalDistance(coordinate),
                    )
                } else {
                    gestureDelegate?.onCompatEdgeProgress(progress(coordinate))
                }
            }
            MotionEvent.ACTION_UP -> {
                val currentCoordinate = if (activeAxis == GestureAxis.VERTICAL) event.y else event.x
                velocityTracker?.computeCurrentVelocity(1_000)
                val rawVelocity = if (activeAxis == GestureAxis.VERTICAL) {
                    velocityTracker?.getYVelocity(activePointerID) ?: 0f
                } else {
                    velocityTracker?.getXVelocity(activePointerID) ?: 0f
                }
                val forwardVelocity = if (activeAxis == GestureAxis.VERTICAL) {
                    rawVelocity
                } else {
                    rawVelocity * horizontalDirection()
                }
                if (activeAxis == GestureAxis.VERTICAL && verticalSheetDragEnabled) {
                    finishSheetGesture(forwardVelocity)
                } else {
                    val progress = progress(currentCoordinate)
                    val forwardVelocityDp = forwardVelocity /
                        resources.displayMetrics.density
                    val finish = progress >= 0.42f ||
                        (progress >= 0.12f && forwardVelocityDp >= 700f)
                    finishGesture(commit = finish)
                }
            }
            MotionEvent.ACTION_CANCEL, MotionEvent.ACTION_POINTER_DOWN -> {
                finishGesture(commit = false)
            }
        }
        return true
    }

    override fun onDetachedFromWindow() {
        if (dragging) gestureDelegate?.onCompatEdgeCancel()
        resetGesture()
        super.onDetachedFromWindow()
    }

    override fun onSizeChanged(width: Int, height: Int, oldWidth: Int, oldHeight: Int) {
        super.onSizeChanged(width, height, oldWidth, oldHeight)
        updateGestureExclusion()
    }

    private fun canHandleCompatGesture(): Boolean =
        compatGestureEnabled &&
            (
                Build.VERSION.SDK_INT < 34 ||
                    fullScreenGesture ||
                    gestureDirection != LynxPopGestureDirection.HORIZONTAL
                ) &&
            gestureDelegate != null &&
            isEnabled

    private fun isInsideStartRegion(x: Float, y: Float): Boolean {
        if (fullScreenGesture) return true
        val edgePx = edgeWidthDp.coerceIn(16f, 72f) * resources.displayMetrics.density
        val horizontal = if (isRtl()) x >= width - edgePx else x <= edgePx
        // vertical back 采用从顶部向下的关闭手势；bottom-sheet/fullscreenDrag 可显式允许
        // 任意位置起手，避免默认抢占页面纵向滚动。
        val vertical = y <= edgePx
        return when (gestureDirection) {
            LynxPopGestureDirection.HORIZONTAL -> horizontal
            LynxPopGestureDirection.VERTICAL -> vertical
            LynxPopGestureDirection.MULTI -> horizontal || vertical
        }
    }

    private fun progress(currentCoordinate: Float): Float {
        val distance = if (activeAxis == GestureAxis.VERTICAL) {
            forwardVerticalDistance(currentCoordinate)
        } else {
            forwardHorizontalDistance(currentCoordinate)
        }
        if (activeAxis == GestureAxis.VERTICAL) {
            return LynxBottomSheetMotion.dragProgress(
                distance,
                verticalGestureExtentPx ?: height.coerceAtLeast(1).toFloat(),
            )
        }
        val extent = width.coerceAtLeast(1)
        return (distance / extent).coerceIn(0f, 1f)
    }

    private fun forwardHorizontalDistance(currentX: Float): Float =
        (currentX - downX) * horizontalDirection()

    private fun forwardVerticalDistance(currentY: Float): Float = currentY - downY

    private fun horizontalDirection(): Float = if (isRtl()) -1f else 1f

    private fun isRtl(): Boolean =
        layoutDirection == View.LAYOUT_DIRECTION_RTL

    private fun finishGesture(commit: Boolean) {
        if (commit) gestureDelegate?.onCompatEdgeFinish(0f) else gestureDelegate?.onCompatEdgeCancel()
        resetGesture()
    }

    private fun finishSheetGesture(velocityPxPerSecond: Float) {
        gestureDelegate?.onCompatEdgeFinish(velocityPxPerSecond)
        resetGesture()
    }

    private fun cancelBeforeDrag() {
        possible = false
        velocityTracker?.recycle()
        velocityTracker = null
        activePointerID = MotionEvent.INVALID_POINTER_ID
        activeAxis = GestureAxis.UNDECIDED
    }

    private fun resetGesture() {
        possible = false
        dragging = false
        activePointerID = MotionEvent.INVALID_POINTER_ID
        activeAxis = GestureAxis.UNDECIDED
        velocityTracker?.recycle()
        velocityTracker = null
        parent?.requestDisallowInterceptTouchEvent(false)
    }

    /**
     * API 29-33 手势导航会优先消费系统边缘；仅排除屏幕中部最多 200dp 的窄区域，
     * 让兼容手势可测试，同时避免把整条系统返回边缘据为己有。
     */
    private fun updateGestureExclusion() {
        if (
            Build.VERSION.SDK_INT !in 29..33 ||
            !compatGestureEnabled ||
            fullScreenGesture ||
            gestureDirection == LynxPopGestureDirection.VERTICAL ||
            width <= 0 ||
            height <= 0
        ) {
            if (Build.VERSION.SDK_INT >= 29) systemGestureExclusionRects = emptyList()
            return
        }
        post {
            if (!compatGestureEnabled || width <= 0 || height <= 0) return@post
            val edgePx = (edgeWidthDp * resources.displayMetrics.density).toInt()
                .coerceAtLeast(1)
            val exclusionHeight = (200f * resources.displayMetrics.density).toInt()
                .coerceAtMost(height)
            val top = (height - exclusionHeight) / 2
            val rect = if (isRtl()) {
                Rect(width - edgePx, top, width, top + exclusionHeight)
            } else {
                Rect(0, top, edgePx, top + exclusionHeight)
            }
            systemGestureExclusionRects = listOf(rect)
        }
    }
}
