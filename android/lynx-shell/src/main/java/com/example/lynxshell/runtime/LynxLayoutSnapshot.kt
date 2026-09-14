package com.example.lynxshell.runtime

import android.app.Activity
import android.graphics.Rect
import android.view.View
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.window.layout.FoldingFeature
import androidx.window.layout.WindowInfoTracker
import androidx.window.layout.WindowMetricsCalculator
import java.util.Locale

/** Android Window 与单个 LynxView 的布局快照；尺寸的内部值全部是原始 px。 */
data class LynxLayoutSnapshot(
    val screenWidthPx: Int,
    val screenHeightPx: Int,
    val viewportWidthPx: Int?,
    val viewportHeightPx: Int?,
    val density: Float,
    val safeAreaTopPx: Int,
    val safeAreaRightPx: Int,
    val safeAreaBottomPx: Int,
    val safeAreaLeftPx: Int,
    val orientation: String,
    val windowMode: String,
    val foldingCapability: String,
    val foldingFeature: Map<String, Any>?,
) {
    fun signature(): List<Any?> = listOf(
        screenWidthPx,
        screenHeightPx,
        viewportWidthPx,
        viewportHeightPx,
        density,
        safeAreaTopPx,
        safeAreaRightPx,
        safeAreaBottomPx,
        safeAreaLeftPx,
        orientation,
        windowMode,
        foldingCapability,
        foldingFeature?.toString(),
    )

    fun toGlobalProps(layoutRevision: Long): HashMap<String, Any> {
        val densityValue = density.coerceAtLeast(0.1f)
        val props = hashMapOf<String, Any>(
            "screenWidth" to screenWidthPx / densityValue,
            "screenHeight" to screenHeightPx / densityValue,
            "density" to densityValue,
            "safeAreaTop" to safeAreaTopPx / densityValue,
            "safeAreaRight" to safeAreaRightPx / densityValue,
            "safeAreaBottom" to safeAreaBottomPx / densityValue,
            "safeAreaLeft" to safeAreaLeftPx / densityValue,
            "topHeight" to safeAreaTopPx / densityValue,
            "bottomHeight" to safeAreaBottomPx / densityValue,
            "statusBarHeight" to safeAreaTopPx / densityValue,
            "navigationBarHeight" to safeAreaBottomPx / densityValue,
            "isNotchScreen" to (safeAreaTopPx > 24 * densityValue),
            "orientation" to orientation,
            "windowMode" to windowMode,
            "layoutRevision" to layoutRevision,
            "layoutEnvironmentRevision" to layoutRevision,
            "foldingCapability" to foldingCapability,
        )
        if (viewportWidthPx != null && viewportHeightPx != null) {
            props["viewportWidth"] = viewportWidthPx / densityValue
            props["viewportHeight"] = viewportHeightPx / densityValue
        }
        props["safeAreaInsets"] = hashMapOf<String, Any>(
            "top" to safeAreaTopPx / densityValue,
            "right" to safeAreaRightPx / densityValue,
            "bottom" to safeAreaBottomPx / densityValue,
            "left" to safeAreaLeftPx / densityValue,
        )
        foldingFeature?.let { props["foldingFeature"] = HashMap(it) }
        val layout = hashMapOf<String, Any>(
            "schemaVersion" to 1,
            "revision" to layoutRevision,
            "screenWidth" to screenWidthPx / densityValue,
            "screenHeight" to screenHeightPx / densityValue,
            "viewportWidth" to (viewportWidthPx?.div(densityValue) ?: 0.0),
            "viewportHeight" to (viewportHeightPx?.div(densityValue) ?: 0.0),
            "density" to densityValue,
            "orientation" to orientation,
            "windowMode" to windowMode,
            "safeAreaInsets" to (props["safeAreaInsets"] ?: emptyMap<String, Any>()),
            "capabilities" to hashMapOf<String, Any>(
                "windowMetrics" to "supported",
                "viewportMetrics" to if (viewportWidthPx != null && viewportHeightPx != null) "supported" else "pending",
                "foldStatus" to foldingCapability,
                "creaseGeometry" to if (foldingFeature == null) "unavailable" else "supported",
            ),
        )
        foldingFeature?.let { layout["foldingFeature"] = HashMap(it) }
        props["__lynxShellLayout"] = layout
        return props
    }

    companion object {
        fun capture(activity: Activity, view: View? = null): LynxLayoutSnapshot {
            val displayMetrics = activity.resources.displayMetrics
            val windowBounds = runCatching {
                WindowMetricsCalculator.getOrCreate()
                    .computeCurrentWindowMetrics(activity)
                    .bounds
            }.getOrElse {
                // AndroidX WindowManager 在旧设备不可用时保留 DisplayMetrics 的兼容路径；
                // 该路径只用于当前窗口尺寸兜底，不宣称多窗口下的精确隔离。
                Rect(0, 0, displayMetrics.widthPixels, displayMetrics.heightPixels)
            }
            val widthPx = windowBounds.width().takeIf { it > 0 } ?: displayMetrics.widthPixels
            val heightPx = windowBounds.height().takeIf { it > 0 } ?: displayMetrics.heightPixels
            val insets = ViewCompat.getRootWindowInsets(activity.window.decorView)
                ?.getInsets(WindowInsetsCompat.Type.systemBars())
            val folding = queryFoldingFeature(activity)
            return LynxLayoutSnapshot(
                screenWidthPx = widthPx,
                screenHeightPx = heightPx,
                viewportWidthPx = view?.width?.takeIf { it > 0 },
                viewportHeightPx = view?.height?.takeIf { it > 0 },
                density = displayMetrics.density,
                safeAreaTopPx = insets?.top ?: 0,
                safeAreaRightPx = insets?.right ?: 0,
                safeAreaBottomPx = insets?.bottom ?: 0,
                safeAreaLeftPx = insets?.left ?: 0,
                orientation = when {
                    widthPx > heightPx -> "landscape"
                    widthPx < heightPx -> "portrait"
                    else -> "unknown"
                },
                windowMode = if (isInMultiWindowMode(activity)) "split" else "fullscreen",
                foldingCapability = folding.first,
                foldingFeature = folding.second,
            )
        }

        private fun isInMultiWindowMode(activity: Activity): Boolean =
            activity.isInMultiWindowMode

        private fun queryFoldingFeature(activity: Activity): Pair<String, Map<String, Any>?> {
            val info = runCatching {
                WindowInfoTracker.getOrCreate(activity).getCurrentWindowLayoutInfo(activity)
            }.getOrNull() ?: return "unknown" to null
            val feature = info.displayFeatures.filterIsInstance<FoldingFeature>().firstOrNull()
                ?: return "supported" to null
            val bounds = feature.bounds
            return "supported" to hashMapOf<String, Any>(
                "state" to feature.state.toString().lowercase(Locale.ROOT),
                "orientation" to feature.orientation.toString().lowercase(Locale.ROOT),
                "isSeparating" to feature.isSeparating,
                "occlusionType" to feature.occlusionType.toString().lowercase(Locale.ROOT),
                "bounds" to hashMapOf<String, Any>(
                    "left" to bounds.left,
                    "top" to bounds.top,
                    "right" to bounds.right,
                    "bottom" to bounds.bottom,
                    "width" to bounds.width(),
                    "height" to bounds.height(),
                ),
                "coordinateSpace" to "window_px",
            )
        }
    }
}
