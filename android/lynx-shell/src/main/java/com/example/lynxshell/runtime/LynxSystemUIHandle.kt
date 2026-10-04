package com.example.lynxshell.runtime

import android.app.Activity
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.example.lynxshell.bridge.ShellMessageHub
import com.lynx.tasm.LynxView
import java.lang.ref.WeakReference
import java.util.Locale

/** Core 返回平台事实；composition root 再映射到能力 Module 的 transport。 */
data class LynxSystemUIResult(
    val data: Map<String, Any> = emptyMap(),
    val errorCode: String? = null,
    val message: String = "",
)

/** 当前真实 LynxView 的系统 UI 接缝，不依赖能力 Module 或业务 App。 */
class LynxSystemUIHandle internal constructor(activity: Activity, view: LynxView) {
    private val activityReference = WeakReference(activity)
    private val viewReference = WeakReference(view)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val originalFontScale = view.lynxContext.fontScale
    private val originalOrientation = activity.requestedOrientation
    private val originalLightStatus = WindowInsetsControllerCompat(activity.window, activity.window.decorView).isAppearanceLightStatusBars
    private val originalLightNavigation = WindowInsetsControllerCompat(activity.window, activity.window.decorView).isAppearanceLightNavigationBars
    private var originalStatusVisible = barVisibility(activity, WindowInsetsCompat.Type.statusBars())
    private var originalNavigationVisible = barVisibility(activity, WindowInsetsCompat.Type.navigationBars())
    private var desiredLightStatus: Boolean? = null
    private var desiredLightNavigation: Boolean? = null
    private var desiredStatusVisible: Boolean? = null
    private var desiredNavigationVisible: Boolean? = null
    private var desiredOrientation: Int? = null
    private var currentFontScale = originalFontScale
    private var fontScaleChanged = false
    private var released = false
    private var pendingCompletion: ((LynxSystemUIResult) -> Unit)? = null
    private var pendingPoll: Runnable? = null
    private var pendingRestore: (() -> Unit)? = null

    val sourceView: LynxView? get() = viewReference.get()
    val owningActivity: Activity? get() = activityReference.get()
    val isAvailable: Boolean
        get() = !released && sourceView?.let { it.isAttachedToWindow && ShellMessageHub.isActiveView(it) } == true

    fun setStatusBarStyle(style: String): LynxSystemUIResult = setBarStyle(style, navigation = false)
    fun setSystemBarsStyle(style: String): LynxSystemUIResult = setBarStyle(style, navigation = true)

    private fun setBarStyle(style: String, navigation: Boolean): LynxSystemUIResult {
        requireMainThread()
        val activity = activeActivity() ?: return failure("HOST_DESTROYED", "调用 LynxView 已失效")
        val normalized = style.uppercase(Locale.US)
        if (normalized !in setOf("LIGHT", "DARK", "DEFAULT")) return failure("INVALID_ARGUMENT", "style 只支持 LIGHT、DARK、DEFAULT")
        val lightStatus = if (normalized == "DEFAULT") originalLightStatus else normalized == "DARK"
        val lightNavigation = if (normalized == "DEFAULT") originalLightNavigation else normalized == "DARK"
        if (navigation && Build.VERSION.SDK_INT < 26 && lightNavigation) return failure("UNSUPPORTED", "当前系统不能设置深色导航栏图标")
        val controller = WindowInsetsControllerCompat(activity.window, activity.window.decorView)
        val beforeStatus = controller.isAppearanceLightStatusBars
        val beforeNavigation = controller.isAppearanceLightNavigationBars
        controller.isAppearanceLightStatusBars = lightStatus
        if (navigation) controller.isAppearanceLightNavigationBars = lightNavigation
        if (controller.isAppearanceLightStatusBars != lightStatus ||
            (navigation && Build.VERSION.SDK_INT >= 26 && controller.isAppearanceLightNavigationBars != lightNavigation)) {
            controller.isAppearanceLightStatusBars = beforeStatus
            if (navigation) controller.isAppearanceLightNavigationBars = beforeNavigation
            return failure("SYSTEM_UI_REJECTED", "系统未应用请求的栏外观")
        }
        desiredLightStatus = lightStatus
        if (navigation) desiredLightNavigation = lightNavigation
        return LynxSystemUIResult(mapOf("style" to normalized, "statusBarIcons" to if (lightStatus) "dark" else "light", "applied" to true))
    }

    fun setBarsVisible(type: String, visible: Boolean, complete: (LynxSystemUIResult) -> Unit) {
        requireMainThread()
        val activity = activeActivity() ?: return complete(failure("HOST_DESTROYED", "调用 LynxView 已失效"))
        if (pendingCompletion != null) return complete(failure("BUSY", "当前页面正在等待系统 UI 更新"))
        val mask = when (type.lowercase(Locale.US)) {
            "statusbar", "statusbars", "status" -> WindowInsetsCompat.Type.statusBars()
            "navigationbar", "navigationbars", "navigation" -> WindowInsetsCompat.Type.navigationBars()
            "systembar", "systembars", "system" -> WindowInsetsCompat.Type.statusBars() or WindowInsetsCompat.Type.navigationBars()
            else -> return complete(failure("INVALID_ARGUMENT", "不支持的系统栏类型"))
        }
        val insets = ViewCompat.getRootWindowInsets(activity.window.decorView)
            ?: return complete(failure("UNAVAILABLE", "当前 Window 尚未提供系统栏 Insets"))
        val beforeStatus = insets.isVisible(WindowInsetsCompat.Type.statusBars())
        val beforeNavigation = insets.isVisible(WindowInsetsCompat.Type.navigationBars())
        if (originalStatusVisible == null) originalStatusVisible = beforeStatus
        if (originalNavigationVisible == null) originalNavigationVisible = beforeNavigation
        val controller = WindowInsetsControllerCompat(activity.window, activity.window.decorView)
        if (visible) controller.show(mask) else controller.hide(mask)
        awaitSystemState(
            complete = complete,
            failureCode = "SYSTEM_UI_REJECTED",
            success = {
                val current = ViewCompat.getRootWindowInsets(activity.window.decorView)
                val statusMatches = mask and WindowInsetsCompat.Type.statusBars() == 0 || current?.isVisible(WindowInsetsCompat.Type.statusBars()) == visible
                val navigationMatches = mask and WindowInsetsCompat.Type.navigationBars() == 0 || current?.isVisible(WindowInsetsCompat.Type.navigationBars()) == visible
                if (current == null || !statusMatches || !navigationMatches) null else {
                    if (mask and WindowInsetsCompat.Type.statusBars() != 0) desiredStatusVisible = visible
                    if (mask and WindowInsetsCompat.Type.navigationBars() != 0) desiredNavigationVisible = visible
                    LynxSystemUIResult(mapOf("type" to type, "visible" to visible, "applied" to true))
                }
            },
            restoreOnFailure = {
                if (mask and WindowInsetsCompat.Type.statusBars() != 0) applyBarVisibility(activity, WindowInsetsCompat.Type.statusBars(), beforeStatus)
                if (mask and WindowInsetsCompat.Type.navigationBars() != 0) applyBarVisibility(activity, WindowInsetsCompat.Type.navigationBars(), beforeNavigation)
            },
        )
    }

    fun getTextZoom(): LynxSystemUIResult {
        requireMainThread()
        if (!isAvailable) return failure("HOST_DESTROYED", "调用 LynxView 已失效")
        return LynxSystemUIResult(mapOf("value" to currentFontScale.toDouble(), "verification" to "lynx_view_request"))
    }

    fun setTextZoom(value: Double): LynxSystemUIResult {
        requireMainThread()
        if (!value.isFinite() || value.toFloat() <= 0f || !value.toFloat().isFinite()) return failure("INVALID_ARGUMENT", "文字缩放必须是有限正数")
        val view = sourceView?.takeIf { isAvailable } ?: return failure("HOST_DESTROYED", "调用 LynxView 已失效")
        view.updateFontScale(value.toFloat())
        // SDK getter 缓存系统字体比例，不能拿它冒充 nativeUpdateFontScale 的渲染确认。
        currentFontScale = value.toFloat()
        fontScaleChanged = true
        return LynxSystemUIResult(mapOf("value" to currentFontScale.toDouble(), "verification" to "lynx_view_request"))
    }

    fun lockOrientation(orientation: String, complete: (LynxSystemUIResult) -> Unit) {
        requireMainThread()
        val value = orientation.trim().lowercase(Locale.US)
        val requested = when (value) {
            "portrait", "portrait-primary" -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            "portrait-secondary", "landscape-secondary" -> return complete(failure("UNSUPPORTED", "当前 Host 只确认窗口横竖方向，不能确认系统反向旋转"))
            "landscape", "landscape-primary" -> ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
            "any", "full-sensor", "fulluser" -> ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
            "natural" -> ActivityInfo.SCREEN_ORIENTATION_NOSENSOR
            else -> return complete(failure("INVALID_ARGUMENT", "不支持的 orientation"))
        }
        requestOrientation(requested, value, complete)
    }

    fun unlockOrientation(complete: (LynxSystemUIResult) -> Unit) =
        requestOrientation(ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED, "any", complete)

    private fun requestOrientation(requested: Int, requestedName: String, complete: (LynxSystemUIResult) -> Unit) {
        requireMainThread()
        val activity = activeActivity() ?: return complete(failure("HOST_DESTROYED", "调用 LynxView 已失效"))
        if (pendingCompletion != null) return complete(failure("BUSY", "当前页面正在等待系统 UI 更新"))
        val previous = activity.requestedOrientation
        val previousDesired = desiredOrientation
        try {
            activity.requestedOrientation = requested
        } catch (error: RuntimeException) {
            complete(failure("ORIENTATION_FAILED", error.message ?: "系统拒绝方向请求"))
            return
        }
        awaitSystemState(
            complete = complete,
            failureCode = "ORIENTATION_FAILED",
            success = {
                val axis = activity.resources.configuration.orientation
                val expectedAxis = when (requested) {
                    ActivityInfo.SCREEN_ORIENTATION_PORTRAIT, ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT -> Configuration.ORIENTATION_PORTRAIT
                    ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE, ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE -> Configuration.ORIENTATION_LANDSCAPE
                    else -> axis
                }
                if (activity.requestedOrientation != requested || axis != expectedAxis || axis == Configuration.ORIENTATION_UNDEFINED) null else {
                    desiredOrientation = requested
                    LynxSystemUIResult(mapOf(
                        "locked" to (requested != ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED),
                        "orientation" to if (axis == Configuration.ORIENTATION_LANDSCAPE) "landscape" else "portrait",
                        "requested" to requestedName,
                        "verification" to "window_orientation",
                        "applied" to true,
                    ))
                }
            },
            restoreOnFailure = {
                activity.requestedOrientation = previous
                desiredOrientation = previousDesired
            },
        )
    }

    /** 等系统实际 Insets/配置；超时是请求失败边界，不代表业务页面健康。 */
    private fun awaitSystemState(
        complete: (LynxSystemUIResult) -> Unit,
        failureCode: String,
        success: () -> LynxSystemUIResult?,
        restoreOnFailure: () -> Unit,
    ) {
        pendingCompletion = complete
        pendingRestore = restoreOnFailure
        val deadline = SystemClock.uptimeMillis() + 2_000L
        val poll = object : Runnable {
            override fun run() {
                if (pendingPoll !== this) return
                if (!isAvailable) {
                    finishPending(failure("HOST_DESTROYED", "调用 LynxView 已失效"))
                    return
                }
                val result = success()
                if (result != null) finishPending(result)
                else if (SystemClock.uptimeMillis() >= deadline) {
                    restoreOnFailure()
                    finishPending(failure(failureCode, "系统未在请求期限内应用目标状态"))
                } else mainHandler.postDelayed(this, 20L)
            }
        }
        pendingPoll = poll
        mainHandler.post(poll)
    }

    private fun finishPending(result: LynxSystemUIResult, restorePendingState: Boolean = false) {
        if (restorePendingState) pendingRestore?.invoke()
        pendingRestore = null
        pendingPoll?.let(mainHandler::removeCallbacks)
        pendingPoll = null
        val complete = pendingCompletion
        pendingCompletion = null
        complete?.invoke(result)
    }

    /** Tab 失去 active owner 后取消请求，恢复 Window；保留该页已确认的期望值供再次选中。 */
    fun deactivate() {
        requireMainThread()
        finishPending(failure("HOST_DESTROYED", "调用页面已不再是当前系统 UI owner"), restorePendingState = true)
        restoreWindow()
    }

    /** 重新选中同一个 View 时只重放其已确认的 Window 状态，不修改其他 View 的文字缩放。 */
    fun activate() {
        requireMainThread()
        val activity = activeActivity() ?: return
        val controller = WindowInsetsControllerCompat(activity.window, activity.window.decorView)
        desiredLightStatus?.let { controller.isAppearanceLightStatusBars = it }
        desiredLightNavigation?.let { controller.isAppearanceLightNavigationBars = it }
        desiredStatusVisible?.let { applyBarVisibility(activity, WindowInsetsCompat.Type.statusBars(), it) }
        desiredNavigationVisible?.let { applyBarVisibility(activity, WindowInsetsCompat.Type.navigationBars(), it) }
        desiredOrientation?.let { activity.requestedOrientation = it }
    }

    /** 调用者只在该来源仍为 active owner 时允许恢复共享 Window。 */
    fun release(restoreWindowState: Boolean) {
        requireMainThread()
        if (released) return
        finishPending(failure("HOST_DESTROYED", "调用页面已销毁"), restorePendingState = restoreWindowState)
        if (restoreWindowState) restoreWindow()
        if (fontScaleChanged) sourceView?.updateFontScale(originalFontScale)
        released = true
    }

    private fun restoreWindow() {
        val activity = owningActivity?.takeUnless { it.isDestroyed || it.isFinishing } ?: return
        val controller = WindowInsetsControllerCompat(activity.window, activity.window.decorView)
        if (desiredLightStatus != null) controller.isAppearanceLightStatusBars = originalLightStatus
        if (desiredLightNavigation != null) controller.isAppearanceLightNavigationBars = originalLightNavigation
        if (desiredStatusVisible != null) originalStatusVisible?.let { applyBarVisibility(activity, WindowInsetsCompat.Type.statusBars(), it) }
        if (desiredNavigationVisible != null) originalNavigationVisible?.let { applyBarVisibility(activity, WindowInsetsCompat.Type.navigationBars(), it) }
        if (desiredOrientation != null) activity.requestedOrientation = originalOrientation
    }

    private fun activeActivity(): Activity? = owningActivity?.takeIf { isAvailable }
    private fun requireMainThread() = check(Looper.myLooper() == Looper.getMainLooper()) { "System UI 必须在主线程调用" }

    private fun failure(code: String, message: String) = LynxSystemUIResult(errorCode = code, message = message)
    private fun barVisibility(activity: Activity, type: Int): Boolean? =
        ViewCompat.getRootWindowInsets(activity.window.decorView)?.isVisible(type)
    private fun applyBarVisibility(activity: Activity, type: Int, visible: Boolean) {
        val controller = WindowInsetsControllerCompat(activity.window, activity.window.decorView)
        if (visible) controller.show(type) else controller.hide(type)
    }
}
