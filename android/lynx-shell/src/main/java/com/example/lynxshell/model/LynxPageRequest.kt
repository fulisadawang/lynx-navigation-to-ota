package com.example.lynxshell.model

import android.content.Intent
import android.net.Uri
import com.example.lynxshell.BuildConfig
import com.example.lynxshell.util.JsonObjectCodec

/** 一个 Lynx 原生页面的完整、可序列化描述。 */
data class LynxPageRequest(
    val bundleUrl: String,
    /** OTA 的逻辑应用身份；与 bundleName 同时存在时才进入 Activity-first OTA。 */
    val lynxAppId: String? = null,
    /** OTA Manifest 中的精确 Bundle 路径/文件名，不是本地绝对路径。 */
    val bundleName: String? = null,
    /** 页面栈稳定标识；未显式传入时使用规范化后的 Bundle URL。 */
    val routeKey: String = "",
    val title: String = "Lynx",
    val initDataJson: String = "{}",
    val globalPropsJson: String = "{}",
    /**
     * Bundle 默认采用 edge-to-edge，占满 Window 并绘制到透明系统栏后方。
     *
     * fullscreen 只决定内容是否延伸到系统栏区域，不再等价于隐藏状态栏。
     */
    val fullscreen: Boolean = true,
    val showToolbar: Boolean = !fullscreen,
    /** 默认保留状态栏图标；只有显式 hide_status_bar=true 才真正隐藏。 */
    val hideStatusBar: Boolean = false,
    /** 是否允许系统 Back 手势/按键直接退出当前 Lynx 页面；原生 Toolbar 返回不受影响。 */
    val backGestureEnabled: Boolean = true,
    val allowHttpInDebug: Boolean = false,
    val orientation: PageOrientation = PageOrientation.SYSTEM,
    /** 页面获得输入焦点后，Window 如何处理 IME 遮挡。默认交给 Android 系统选择。 */
    val keyboardBehavior: KeyboardBehavior = KeyboardBehavior.SYSTEM,
    val backgroundColor: String = "#FFFFFF",
    val widthPx: Int? = null,
    val heightPx: Int? = null,
    val density: Float? = null,
) {
    /**
     * 在创建 LynxView 之前完成边界校验。
     *
     * 远程 Bundle 可使用任意 HTTPS Host；协议、页面参数和本地路径仍需通过校验。
     */
    fun validated(): LynxPageRequest {
        require(bundleUrl.isNotBlank()) { "Bundle URL 不能为空" }
        require(isSupportedBundleUrl(bundleUrl)) { "不支持的 Bundle URL: $bundleUrl" }
        val hasAppId = !lynxAppId.isNullOrBlank()
        val hasBundleName = !bundleName.isNullOrBlank()
        require(hasAppId == hasBundleName) {
            "OTA 请求必须同时提供 lynxAppId 和 bundleName"
        }
        require(!isRemoteBundleUrl(bundleUrl) || (!hasAppId && !hasBundleName)) {
            "HTTPS Bundle 是直连页面，不能携带 OTA 的 lynxAppId/bundleName"
        }
        if (hasAppId) {
            require(lynxAppId!!.length <= 256) { "lynxAppId 不能超过 256 个字符" }
            require(bundleName!!.length <= 2_048) { "bundleName 不能超过 2048 个字符" }
            require(bundleName.endsWith(".lynx.bundle", ignoreCase = true)) {
                "bundleName 必须以 .lynx.bundle 结尾"
            }
            require(
                !bundleName.startsWith('/') &&
                    !bundleName.contains('\\') &&
                    !bundleName.contains('\u0000') &&
                    bundleName.split('/').none { it.isBlank() || it == "." || it == ".." },
            ) { "bundleName 含有不安全路径段" }
        }
        require(resolvedRouteKey().length <= 256) { "routeKey 不能超过 256 个字符" }

        if (isRemoteBundleUrl(bundleUrl)) {
            val uri = Uri.parse(bundleUrl)
            val host = uri.host.orEmpty().lowercase()
            require(host.isNotBlank()) { "远程 Bundle URL 缺少合法域名" }
            if (bundleUrl.lowercase().startsWith("http://")) {
                require(BuildConfig.DEBUG && allowHttpInDebug) { "生产配置禁止加载明文 HTTP Bundle" }
            }
        }

        JsonObjectCodec.requireObject(initDataJson, "initData")
        JsonObjectCodec.requireObject(globalPropsJson, "globalProps")
        widthPx?.let { require(it > 0) { "width 必须大于 0" } }
        heightPx?.let { require(it > 0) { "height 必须大于 0" } }
        density?.let { require(it > 0f) { "density 必须大于 0" } }
        require(Regex("^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$").matches(backgroundColor)) {
            "backgroundColor 必须为 #RRGGBB 或 #RRGGBBAA"
        }
        return this
    }

    fun writeTo(intent: Intent): Intent = intent.apply {
        putExtra(EXTRA_BUNDLE_URL, bundleUrl)
        if (lynxAppId != null) putExtra(EXTRA_LYNX_APP_ID, lynxAppId)
        else removeExtra(EXTRA_LYNX_APP_ID)
        if (bundleName != null) putExtra(EXTRA_BUNDLE_NAME, bundleName)
        else removeExtra(EXTRA_BUNDLE_NAME)
        putExtra(EXTRA_ROUTE_KEY, resolvedRouteKey())
        putExtra(EXTRA_TITLE, title)
        putExtra(EXTRA_INIT_DATA, initDataJson)
        putExtra(EXTRA_GLOBAL_PROPS, globalPropsJson)
        putExtra(EXTRA_FULLSCREEN, fullscreen)
        putExtra(EXTRA_SHOW_TOOLBAR, showToolbar)
        putExtra(EXTRA_HIDE_STATUS_BAR, hideStatusBar)
        putExtra(EXTRA_BACK_GESTURE_ENABLED, backGestureEnabled)
        putExtra(EXTRA_ALLOW_HTTP, allowHttpInDebug)
        putExtra(EXTRA_ORIENTATION, orientation.name)
        putExtra(EXTRA_KEYBOARD_BEHAVIOR, keyboardBehavior.wireName)
        putExtra(EXTRA_BACKGROUND_COLOR, backgroundColor)
        widthPx?.let { putExtra(EXTRA_WIDTH, it) }
        heightPx?.let { putExtra(EXTRA_HEIGHT, it) }
        density?.let { putExtra(EXTRA_DENSITY, it) }
    }

    fun resolvedRouteKey(): String = routeKey.trim().ifBlank {
        bundleName?.trim()?.takeIf { it.isNotBlank() } ?: bundleUrl.trim()
    }

    /** 只有显式逻辑身份的请求才是 OTA；不能根据本地缓存目录猜 appId。 */
    fun isOtaRequest(): Boolean =
        !isRemoteBundleUrl(bundleUrl) && !lynxAppId.isNullOrBlank() && !bundleName.isNullOrBlank()

    companion object {
        const val EXTRA_BUNDLE_URL = "lynx_shell.bundle_url"
        const val EXTRA_LYNX_APP_ID = "lynx_shell.lynx_app_id"
        const val EXTRA_BUNDLE_NAME = "lynx_shell.bundle_name"
        const val EXTRA_ROUTE_KEY = "lynx_shell.route_key"
        const val EXTRA_TITLE = "lynx_shell.title"
        const val EXTRA_INIT_DATA = "lynx_shell.init_data"
        const val EXTRA_GLOBAL_PROPS = "lynx_shell.global_props"
        const val EXTRA_FULLSCREEN = "lynx_shell.fullscreen"
        const val EXTRA_SHOW_TOOLBAR = "lynx_shell.show_toolbar"
        const val EXTRA_HIDE_STATUS_BAR = "lynx_shell.hide_status_bar"
        const val EXTRA_BACK_GESTURE_ENABLED = "lynx_shell.back_gesture_enabled"
        const val EXTRA_ALLOW_HTTP = "lynx_shell.allow_http"
        const val EXTRA_ORIENTATION = "lynx_shell.orientation"
        const val EXTRA_KEYBOARD_BEHAVIOR = "lynx_shell.keyboard_behavior"
        const val EXTRA_BACKGROUND_COLOR = "lynx_shell.background_color"
        const val EXTRA_WIDTH = "lynx_shell.width"
        const val EXTRA_HEIGHT = "lynx_shell.height"
        const val EXTRA_DENSITY = "lynx_shell.density"

        fun isSupportedBundleUrl(url: String): Boolean {
            val lower = url.lowercase()
            return lower.startsWith("assets://") ||
                lower.startsWith("https://") ||
                lower.startsWith("http://") ||
                lower.startsWith("file://lynx?local://") ||
                (!lower.contains("://") && lower.endsWith(".lynx.bundle"))
        }

        fun isRemoteBundleUrl(url: String): Boolean {
            val lower = url.lowercase()
            return lower.startsWith("https://") || lower.startsWith("http://")
        }

    }
}

enum class PageOrientation {
    SYSTEM,
    PORTRAIT,
    LANDSCAPE,
}

/**
 * Router 请求中的键盘布局策略。
 *
 * Android 的具体 Window 常量和 edge-to-edge Insets 处理留在容器层，路由只携带语义；
 * HarmonyOS/iOS 由各自平台容器映射到原生键盘避让 API。
 */
enum class KeyboardBehavior(val wireName: String) {
    SYSTEM("system"),
    RESIZE("resize"),
    PAN("pan"),
    NOTHING("nothing"),
}
