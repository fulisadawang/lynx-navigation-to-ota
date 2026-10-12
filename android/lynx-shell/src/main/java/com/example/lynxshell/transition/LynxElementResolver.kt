package com.example.lynxshell.transition

import android.graphics.Rect
import android.view.View
import com.lynx.tasm.LynxView
import com.lynx.tasm.behavior.ui.LynxBaseUI
import com.lynx.tasm.behavior.ui.LynxUI

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

        // SDK ID 索引可保留已脱离树的同 ID 节点；几何只从当前根树读取。
        val ui = findCurrent(view.lynxUIRoot, normalized) ?: return null
        val nativeView = (ui as? LynxUI<*>)?.view
        val rect = nativeView?.takeIf(::isUsableView)?.let(::rectOnScreen)
            ?: ui.rectToWindow
        if (rect == null || rect.isEmpty || !intersectsVisibleWindow(view, rect)) return null
        return ResolvedLynxElement(
            selector = normalized,
            rectOnScreen = Rect(rect),
            nativeView = nativeView?.takeIf(::isUsableView),
        )
    }

    private fun findCurrent(ui: LynxBaseUI?, id: String): LynxBaseUI? {
        if (ui == null) return null
        if (ui.idSelector == id) return ui
        for (child in ui.children) findCurrent(child, id)?.let { return it }
        return null
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
