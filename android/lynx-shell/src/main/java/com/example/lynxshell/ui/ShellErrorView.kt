package com.example.lynxshell.ui

import android.content.Context
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
import com.example.lynxshell.R
import com.google.android.material.button.MaterialButton

/** 原生错误态：明确展示失败原因，并由用户决定是否重试。 */
class ShellErrorView(context: Context) : LinearLayout(context) {
    private val titleView = TextView(context)
    private val detailView = TextView(context)
    private val retryButton = MaterialButton(context)

    var onRetry: (() -> Unit)? = null

    init {
        orientation = VERTICAL
        gravity = Gravity.CENTER
        setPadding(dp(32), dp(32), dp(32), dp(32))
        setBackgroundColor(resolveSurfaceColor())

        titleView.text = "Lynx 页面加载失败"
        titleView.textSize = 20f
        titleView.gravity = Gravity.CENTER

        detailView.textSize = 14f
        detailView.gravity = Gravity.CENTER
        detailView.setPadding(0, dp(12), 0, dp(20))

        retryButton.setText(R.string.retry)
        retryButton.setOnClickListener { onRetry?.invoke() }

        addView(titleView, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        addView(detailView, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        addView(retryButton, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT))
        visibility = View.GONE
    }

    fun show(message: String) {
        detailView.text = message
        visibility = View.VISIBLE
        bringToFront()
    }

    fun hide() {
        visibility = View.GONE
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private fun resolveSurfaceColor(): Int {
        val typedValue = android.util.TypedValue()
        context.theme.resolveAttribute(com.google.android.material.R.attr.colorSurface, typedValue, true)
        return typedValue.data
    }
}
