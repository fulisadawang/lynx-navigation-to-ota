package com.example.lynxshell.runtime

import android.app.Activity
import android.content.res.Configuration
import android.os.Build
import android.view.View
import com.example.lynxshell.model.LynxPageRequest
import com.example.lynxshell.routing.LynxNavigator
import com.example.lynxshell.transition.LynxTransitionIntent
import com.example.lynxshell.util.JsonObjectCodec
import com.lynx.tasm.LynxColorScheme

/** 构造两端约定的宿主全局参数；系统保留字段不允许页面覆盖。 */
object ShellGlobalPropsFactory {
    /** 将当前 Activity 的有效夜间模式映射为 Lynx 4.0 两态颜色枚举。 */
    fun resolveColorScheme(activity: Activity): LynxColorScheme =
        if (isDarkTheme(activity)) LynxColorScheme.DARK else LynxColorScheme.LIGHT

    /** 与页面 GlobalProps 使用同一份主题判定，避免引擎和页面出现不同步。 */
    fun resolveThemeName(activity: Activity): String =
        if (isDarkTheme(activity)) "Dark" else "Light"

    private fun isDarkTheme(activity: Activity): Boolean =
        activity.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
            Configuration.UI_MODE_NIGHT_YES

    /** 供 Builder 和布局协调器读取同一份 WindowMetrics。 */
    fun captureLayout(activity: Activity, view: View? = null): LynxLayoutSnapshot =
        LynxLayoutSnapshot.capture(activity, view)

    /** 构造不依赖具体路由身份的环境字段；GlobalProps 更新会合并这些保留字段。 */
    fun createEnvironment(
        activity: Activity,
        view: View? = null,
        snapshot: LynxLayoutSnapshot = captureLayout(activity, view),
        layoutRevision: Long = 0L,
        locale: LynxLocaleState = LynxLocaleStore.current(activity),
    ): HashMap<String, Any> {
        val props = snapshot.toGlobalProps(layoutRevision)
        props["platform"] = "android"
        props["os"] = "android"
        props["theme"] = resolveThemeName(activity)
        props["frontendTheme"] = "system"
        props["systemVersion"] = Build.VERSION.RELEASE
        props["locale"] = locale.effectiveLocale
        props["language"] = locale.language
        props["appLanguage"] = locale.language
        props["appLocale"] = locale.appLocale ?: org.json.JSONObject.NULL
        props["appLocaleOverride"] = locale.appLocale ?: org.json.JSONObject.NULL
        props["systemLocale"] = locale.systemLocale
        props["localeSource"] = locale.source
        props["localeStatus"] = locale.status
        props["localeRevision"] = locale.revision
        props["direction"] = locale.direction
        props["formatLocale"] = locale.effectiveLocale
        props["__lynxShellLocale"] = locale.toGlobalMap()
        props["layoutCapabilities"] = hashMapOf<String, Any>(
            "windowMetrics" to "supported",
            "viewportMetrics" to if (snapshot.viewportWidthPx != null && snapshot.viewportHeightPx != null) {
                "supported"
            } else {
                "pending"
            },
            "foldStatus" to snapshot.foldingCapability,
            "creaseGeometry" to if (snapshot.foldingFeature == null) "unavailable" else "supported",
        )
        val packageInfo = activity.packageManager.getPackageInfo(activity.packageName, 0)
        props["appVersion"] = packageInfo.versionName ?: ""
        props["buildNumber"] = if (Build.VERSION.SDK_INT >= 28) {
            packageInfo.longVersionCode.toString()
        } else {
            @Suppress("DEPRECATION") packageInfo.versionCode.toString()
        }
        return props
    }

    fun create(
        activity: Activity,
        request: LynxPageRequest,
        bundleMetadata: Map<String, Any>? = null,
        initialLayout: LynxLayoutSnapshot? = null,
    ): HashMap<String, Any> {
        val props = JsonObjectCodec.toMap(request.globalPropsJson, "globalProps")
        props.putAll(
            createEnvironment(
                activity = activity,
                snapshot = initialLayout ?: captureLayout(activity),
            ),
        )
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
        val locale = LynxLocaleStore.current(activity)
        queryItems["locale"] = locale.effectiveLocale
        queryItems["language"] = locale.language
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
        bundleMetadata?.let { props["__lynxBundleMeta"] = HashMap(it) }
        // 目标页在首屏 Bundle 执行前即可读取 transactionID，并据此调用 markTransitionReady。
        LynxTransitionIntent.globalProps(activity.intent)?.let {
            props["nativeTransition"] = it
        }
        return props
    }
}
