package com.example.lynxshell.ui

import android.content.Context
import android.graphics.Color
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import kotlin.math.roundToInt

/**
 * OTA 页面准备阶段的原生 Loading Surface。
 *
 * Loading 必须在创建 LynxView 之前出现：下载、校验和 current 激活期间不能让空的
 * LynxView 或主题默认背景先露出来，否则页面转场会出现白/黑闪烁。首屏回调到达后由
 * LynxShellActivity 隐藏本 View。
 */
class ShellLoadingView(context: Context) : LinearLayout(context) {
    private val messageView = TextView(context)

    init {
        orientation = VERTICAL
        gravity = Gravity.CENTER
        setPadding(dp(32), dp(32), dp(32), dp(32))
        setBackgroundColor(Color.WHITE)

        addView(
            ProgressBar(context).apply { isIndeterminate = true },
            LayoutParams(dp(40), dp(40)),
        )
        addView(
            messageView.apply {
                text = "正在准备 Lynx 页面…"
                textSize = 15f
                setTextColor(Color.rgb(80, 84, 96))
                gravity = Gravity.CENTER
            },
            LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply {
                topMargin = dp(16)
            },
        )
        visibility = View.GONE
    }

    /** 更新阶段文案并显示 Loading；只在主线程调用。 */
    fun show(message: String = "正在准备 Lynx 页面…") {
        messageView.text = message
        visibility = View.VISIBLE
        bringToFront()
    }

    /** 隐藏 Loading，让已完成首屏的 LynxView 接管 Surface。 */
    fun hide() {
        visibility = View.GONE
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).roundToInt()
}
