package com.example.lynxshell.debug

import android.app.Activity
import android.app.Application
import android.graphics.Color
import android.graphics.PixelFormat
import android.os.Bundle
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.view.Gravity
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.TextView
import kotlin.math.roundToInt

/**
 * App 内全局调试入口。
 *
 * 这是 Application 级 Activity 生命周期管理的窗口级 overlay，不是某个 Lynx 页面
 * content view 的子 View；它会在当前前台 Activity 切换时重新挂到新的宿主 Window，
 * 因此跨 Router 页面和多个 Activity 仍保持同一个入口语义。不申请系统悬浮窗权限。
 */
internal object LynxDebugFloatingBallManager {
    private var enabled = false
    private var currentActivity: Activity? = null
    private var overlay: TextView? = null
    private var overlayParams: WindowManager.LayoutParams? = null
    private var application: Application? = null
    private var downRawX = 0f
    private var downRawY = 0f
    private var startX = 0
    private var startY = 0
    private var moved = false

    private val callbacks = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityResumed(activity: Activity) {
            if (activity is LynxDebugActivity) return
            currentActivity = activity
            activity.window.decorView.post { installFor(activity) }
        }

        override fun onActivityPaused(activity: Activity) {
            if (currentActivity === activity) removeFrom(activity)
        }

        override fun onActivityDestroyed(activity: Activity) {
            if (currentActivity === activity) {
                removeFrom(activity)
                currentActivity = null
            }
        }

        override fun onActivityCreated(activity: Activity, state: Bundle?) = Unit
        override fun onActivityStarted(activity: Activity) = Unit
        override fun onActivityStopped(activity: Activity) = Unit
        override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) = Unit
    }

    fun install(value: Application) {
        if (application === value) return
        application?.unregisterActivityLifecycleCallbacks(callbacks)
        application = value
        value.registerActivityLifecycleCallbacks(callbacks)
    }

    fun setEnabled(value: Boolean) {
        enabled = value
        val activity = currentActivity ?: return
        if (value) activity.window.decorView.post { installFor(activity) } else removeFrom(activity)
    }

    private fun installFor(activity: Activity) {
        if (!enabled || activity.isFinishing || activity.isDestroyed || activity is LynxDebugActivity) return
        removeFrom(activity)
        val decor = activity.window.decorView
        val token = decor.windowToken ?: return
        val tag = TextView(activity).apply {
            text = "Lynx"
            textSize = 12f
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.rgb(0, 110, 255))
            gravity = Gravity.CENTER
            isClickable = true
            isFocusable = true
            contentDescription = "打开 Lynx 调试面板"
            setOnClickListener { LynxDebugTool.show(activity) }
        }
        val size = (28 * activity.resources.displayMetrics.density).roundToInt()
        val width = (78 * activity.resources.displayMetrics.density).roundToInt()
        val params = WindowManager.LayoutParams(
            width,
            size,
            WindowManager.LayoutParams.TYPE_APPLICATION_PANEL,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.START or Gravity.BOTTOM
            this.token = token
            x = position(activity, POSITION_X, 0)
            y = position(activity, POSITION_Y, (24 * activity.resources.displayMetrics.density).roundToInt())
        }
        tag.setOnTouchListener { view, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downRawX = event.rawX
                    downRawY = event.rawY
                    startX = params.x
                    startY = params.y
                    moved = false
                    true
                }

                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - downRawX
                    val dy = event.rawY - downRawY
                    val slop = ViewConfiguration.get(activity).scaledTouchSlop
                    if (!moved && kotlin.math.hypot(dx.toDouble(), dy.toDouble()) > slop) moved = true
                    if (moved) {
                        params.x = (startX + dx).roundToInt()
                        params.y = (startY - dy).roundToInt()
                        clamp(params, activity, view)
                        runCatching { activity.windowManager.updateViewLayout(view, params) }
                    }
                    true
                }

                MotionEvent.ACTION_UP -> {
                    if (moved) {
                        savePosition(activity, params)
                    } else {
                        view.performClick()
                    }
                    true
                }

                MotionEvent.ACTION_CANCEL -> {
                    if (moved) savePosition(activity, params)
                    true
                }

                else -> false
            }
        }
        runCatching { activity.windowManager.addView(tag, params) }
            .onSuccess {
                overlay = tag
                overlayParams = params
            }
    }

    private fun removeFrom(activity: Activity) {
        val view = overlay ?: return
        overlay = null
        overlayParams = null
        runCatching { activity.windowManager.removeViewImmediate(view) }
    }

    private fun position(activity: Activity, key: String, fallback: Int): Int =
        activity.getSharedPreferences(PREFS_NAME, 0).getInt(key, fallback)

    private fun savePosition(activity: Activity, params: WindowManager.LayoutParams) {
        activity.getSharedPreferences(PREFS_NAME, 0).edit()
            .putInt(POSITION_X, params.x)
            .putInt(POSITION_Y, params.y)
            .apply()
    }

    private fun clamp(
        params: WindowManager.LayoutParams,
        activity: Activity,
        view: android.view.View,
    ) {
        val metrics = activity.resources.displayMetrics
        val maxX = (metrics.widthPixels - view.width).coerceAtLeast(0)
        val maxY = (metrics.heightPixels - view.height).coerceAtLeast(0)
        params.x = params.x.coerceIn(0, maxX)
        params.y = params.y.coerceIn(0, maxY)
    }

    private const val PREFS_NAME = "lynx_debug_tool"
    private const val POSITION_X = "floating_x"
    private const val POSITION_Y = "floating_y"
}
