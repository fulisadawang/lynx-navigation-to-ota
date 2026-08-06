package com.example.lynxshell.runtime

import android.app.Activity
import android.content.res.Configuration
import android.os.Build
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.example.lynxshell.model.LynxPageRequest
import com.example.lynxshell.routing.LynxNavigator
import com.example.lynxshell.transition.LynxTransitionIntent
import com.example.lynxshell.util.JsonObjectCodec
import java.util.Locale

/** 构造两端约定的宿主全局参数；系统保留字段不允许页面覆盖。 */
object ShellGlobalPropsFactory {
    fun create(activity: Activity, request: LynxPageRequest): HashMap<String, Any> {
        val metrics = activity.resources.displayMetrics
        val insets = ViewCompat.getRootWindowInsets(activity.window.decorView)
        val systemBars = insets?.getInsets(WindowInsetsCompat.Type.systemBars())
        val props = JsonObjectCodec.toMap(request.globalPropsJson, "globalProps")
        val safeAreaTop = (systemBars?.top ?: 0) / metrics.density
        val safeAreaBottom = (systemBars?.bottom ?: 0) / metrics.density
        val safeAreaLeft = (systemBars?.left ?: 0) / metrics.density
        val safeAreaRight = (systemBars?.right ?: 0) / metrics.density

        props["platform"] = "android"
        // Sparkling Playground 的旧字段名。保留壳字段，同时提供兼容别名。
        props["os"] = "android"
        props["screenWidth"] = metrics.widthPixels / metrics.density
        props["screenHeight"] = metrics.heightPixels / metrics.density
        props["density"] = metrics.density
        props["safeAreaTop"] = safeAreaTop
        props["safeAreaBottom"] = safeAreaBottom
        props["safeAreaLeft"] = safeAreaLeft
        props["safeAreaRight"] = safeAreaRight
        props["topHeight"] = safeAreaTop
        props["bottomHeight"] = safeAreaBottom
        props["statusBarHeight"] = safeAreaTop
        props["navigationBarHeight"] = safeAreaBottom
        props["isNotchScreen"] = (systemBars?.top ?: 0) > 24 * metrics.density
        props["theme"] = if (
            activity.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
            Configuration.UI_MODE_NIGHT_YES
        ) "Dark" else "Light"
        props["frontendTheme"] = "system"
        props["systemVersion"] = Build.VERSION.RELEASE
        props["locale"] = Locale.getDefault().toLanguageTag()

        val packageInfo = activity.packageManager.getPackageInfo(activity.packageName, 0)
        props["appVersion"] = packageInfo.versionName ?: ""
        props["buildNumber"] = if (Build.VERSION.SDK_INT >= 28) {
            packageInfo.longVersionCode.toString()
        } else {
            @Suppress("DEPRECATION") packageInfo.versionCode.toString()
        }
        // 页面应读取“原生最终采用”的 chrome 状态，而不是调用方可能遗漏或互相冲突的
        // 原始参数。保留其他 queryItems，并覆盖这四个宿主保留字段。
        val queryItems = hashMapOf<String, Any>()
        (props["queryItems"] as? Map<*, *>)?.forEach { (key, value) ->
            if (key is String && value != null) {
                queryItems[key] = value
            }
        }
        queryItems["fullscreen"] = if (request.fullscreen) "1" else "0"
        queryItems["hide_nav_bar"] = if (request.showToolbar) "0" else "1"
        queryItems["hide_status_bar"] = if (request.hideStatusBar) "1" else "0"
        queryItems["trans_status_bar"] =
            if (request.fullscreen && !request.hideStatusBar) "1" else "0"
        props["queryItems"] = queryItems
        // Native Page Stack 身份必须按页面实例生成：同一个 Bundle 多次 push 不能共享
        // containerID，否则 sendToPage 会把消息误投到旧 Activity。
        val identity = (activity as? com.example.lynxshell.container.LynxShellActivity)
            ?.let(LynxNavigator::routerPageIdentity)
        val pageId = identity?.entryID ?: "lynx-shell-${request.bundleUrl.hashCode()}"
        props["containerID"] = pageId
        props["__lynxRouterContainerId"] = pageId
        props["__lynxRouterPageId"] = pageId
        props["__lynxRouterPageKey"] = identity?.routeKey ?: request.resolvedRouteKey()
        props["__lynxRouterSessionId"] = identity?.sessionID ?: ""
        props["__lynxRouterNavigationModel"] = "native_page_stack"
        props["__lynxRouterPlatformContainer"] = "android_activity"
        props["__lynxRouterParams"] = queryItems
        // 目标页在首屏 Bundle 执行前即可读取 transactionID，并据此调用 markTransitionReady。
        LynxTransitionIntent.globalProps(activity.intent)?.let {
            props["nativeTransition"] = it
        }
        return props
    }
}
