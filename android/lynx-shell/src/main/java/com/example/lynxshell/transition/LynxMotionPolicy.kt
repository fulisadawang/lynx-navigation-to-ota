package com.example.lynxshell.transition

import android.animation.ValueAnimator
import android.content.Context
import android.os.Build
import android.provider.Settings

data class LynxResolvedMotion(
    val style: LynxTransitionStyle,
    val durationMs: Long,
    val reason: String? = null,
)

/** 集中处理 animated=false、系统动画关闭和 Reduce Motion，不让各动画分支各自猜测。 */
object LynxMotionPolicy {
    fun resolve(
        context: Context,
        requested: LynxTransitionStyle,
        durationMs: Long,
        animated: Boolean,
    ): LynxResolvedMotion {
        if (!animated) {
            return LynxResolvedMotion(
                style = LynxTransitionStyle.NONE,
                durationMs = 0L,
            )
        }
        if (!areAnimationsEnabled(context)) {
            return LynxResolvedMotion(
                style = LynxTransitionStyle.NONE,
                durationMs = 0L,
                reason = "reduce_motion",
            )
        }
        return LynxResolvedMotion(requested, durationMs)
    }

    @Suppress("DEPRECATION")
    private fun areAnimationsEnabled(context: Context): Boolean {
        val valueAnimatorEnabled = Build.VERSION.SDK_INT < 26 || ValueAnimator.areAnimatorsEnabled()
        val durationScale = runCatching {
            Settings.Global.getFloat(
                context.contentResolver,
                Settings.Global.ANIMATOR_DURATION_SCALE,
                1f,
            )
        }.getOrDefault(1f)
        return valueAnimatorEnabled && durationScale > 0f
    }
}
