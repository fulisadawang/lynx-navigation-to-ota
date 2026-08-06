package com.example.lynxshell.transition

import android.graphics.Rect
import android.view.View
import com.lynx.tasm.LynxView

data class ResolvedLynxElement(
    val selector: String,
    val rectOnScreen: Rect,
    val nativeView: View?,
)

/** 所有 selector 和几何都由 UI 主线程读取真实 Lynx 节点，不信任 JS 上报坐标。 */
object LynxElementResolver {
    fun resolve(lynxView: LynxView?, selector: String): ResolvedLynxElement? {
        checkMainThread()
        val view = lynxView ?: return null
        val normalized = selector.trim().removePrefix("#")
        if (normalized.isEmpty()) return null

        val nativeView = view.findViewByIdSelector(normalized)
        val rect = nativeView?.takeIf(::isUsableView)?.let(::rectOnScreen)
            ?: view.findUIByIdSelector(normalized)?.getRectToWindow()
        if (rect == null || rect.isEmpty || !intersectsVisibleWindow(view, rect)) return null
        return ResolvedLynxElement(
            selector = normalized,
            rectOnScreen = Rect(rect),
            nativeView = nativeView?.takeIf(::isUsableView),
        )
    }

    fun rectOnScreen(view: View): Rect {
        val location = IntArray(2)
        view.getLocationOnScreen(location)
        return Rect(
            location[0],
            location[1],
            location[0] + view.width,
            location[1] + view.height,
        )
    }

    private fun isUsableView(view: View): Boolean =
        view.isAttachedToWindow &&
            view.visibility == View.VISIBLE &&
            view.alpha > 0f &&
            view.width > 0 &&
            view.height > 0

    private fun intersectsVisibleWindow(lynxView: LynxView, rect: Rect): Boolean {
        val rootRect = rectOnScreen(lynxView)
        return !rootRect.isEmpty && Rect.intersects(rootRect, rect)
    }

    private fun checkMainThread() {
        check(android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) {
            "Lynx selector 必须在 Android 主线程解析"
        }
    }
}
