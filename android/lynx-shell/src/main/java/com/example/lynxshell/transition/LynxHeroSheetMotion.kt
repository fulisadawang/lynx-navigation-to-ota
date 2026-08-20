package com.example.lynxshell.transition

import kotlin.math.abs

/**
 * heroSheet 的纯档位运动工具。
 *
 * 档位使用 vh 语义，Coordinator 只把这里的结果映射到原生容器；不在动画帧内调用
 * NativeModules、路由或业务状态。Android 的实际拖拽仍由 View 主线程消费。
 */
internal object LynxHeroSheetMotion {
    const val MAX_DETENTS = 4
    const val DEFAULT_INITIAL_DETENT_VH = 56f
    const val DISMISS_VELOCITY_PX_PER_SECOND = 900f
    const val EXPAND_TO_FULLSCREEN_VELOCITY_PX_PER_SECOND = -700f
    const val EXPAND_TO_FULLSCREEN_DISTANCE_FRACTION = 0.08f
    const val VELOCITY_PROJECTION_SECONDS = 0.08f
    val DEFAULT_DETENTS_VH = listOf(28f, 56f, 100f)

    fun nearestDetentIndex(heightVh: Float, detentsVh: List<Float>): Int {
        require(detentsVh.isNotEmpty()) { "heroSheet 至少需要一个 detent" }
        return detentsVh.indices.minByOrNull { index ->
            abs(detentsVh[index] - heightVh)
        } ?: 0
    }

    /** 用释放速度预估下一档；向上拖动的负速度会预估到更大的高度。 */
    fun projectedHeightVh(
        currentHeightVh: Float,
        velocityPxPerSecond: Float,
        rootHeightPx: Float,
    ): Float {
        if (rootHeightPx <= 0f) return currentHeightVh
        return currentHeightVh -
            velocityPxPerSecond * VELOCITY_PROJECTION_SECONDS / rootHeightPx * 100f
    }

    fun shouldDismiss(
        rawHeightPx: Float,
        minimumHeightPx: Float,
        velocityPxPerSecond: Float,
    ): Boolean =
        rawHeightPx < minimumHeightPx * 0.88f ||
            (rawHeightPx <= minimumHeightPx + 1f &&
                velocityPxPerSecond >= DISMISS_VELOCITY_PX_PER_SECOND)

    fun shouldExpandToFullscreen(
        rawHeightPx: Float,
        startHeightPx: Float,
        rootHeightPx: Float,
        velocityPxPerSecond: Float,
    ): Boolean =
        velocityPxPerSecond <= EXPAND_TO_FULLSCREEN_VELOCITY_PX_PER_SECOND ||
            rawHeightPx >= startHeightPx + rootHeightPx * EXPAND_TO_FULLSCREEN_DISTANCE_FRACTION
}
