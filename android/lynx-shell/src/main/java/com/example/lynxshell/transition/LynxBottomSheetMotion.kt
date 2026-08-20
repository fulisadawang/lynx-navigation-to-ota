package com.example.lynxshell.transition

/**
 * iOS-style bottom sheet 的跨 renderer 纯运动模型。
 *
 * Android Coordinator 只负责把这里的单一 progress 应用到真实 View；拖拽、push、pop
 * 和取消都必须复用同一组数值，避免目标 Sheet 与来源页 backdrop 使用两套时间线。
 */
internal object LynxBottomSheetMotion {
    const val DEFAULT_DURATION_MS = 420L
    const val DEFAULT_HEIGHT_VH = 92f
    const val SHEET_CORNER_RADIUS_DP = 20f
    const val BACKDROP_END_SCALE = 0.94f
    const val BACKDROP_END_TRANSLATION_Y_DP = 10f
    const val BACKDROP_END_CORNER_RADIUS_DP = 18f

    data class State(
        val sheetTranslationFraction: Float,
        val backdropScale: Float,
        val backdropTranslationYDp: Float,
        val backdropCornerRadiusDp: Float,
        val barrierAlpha: Float,
    )

    fun state(rawProgress: Float): State {
        val progress = rawProgress.coerceIn(0f, 1f)
        return State(
            sheetTranslationFraction = 1f - progress,
            backdropScale = lerp(1f, BACKDROP_END_SCALE, progress),
            backdropTranslationYDp = BACKDROP_END_TRANSLATION_Y_DP * progress,
            backdropCornerRadiusDp = BACKDROP_END_CORNER_RADIUS_DP * progress,
            barrierAlpha = progress,
        )
    }

    fun dragProgress(distancePx: Float, sheetHeightPx: Float): Float {
        if (sheetHeightPx <= 0f) return 0f
        return (distancePx / sheetHeightPx).coerceIn(0f, 1f)
    }

    private fun lerp(start: Float, end: Float, progress: Float): Float =
        start + (end - start) * progress
}
