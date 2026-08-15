package com.example.lynxshell.routing

import android.content.Intent
import android.net.Uri
import com.example.lynxshell.BuildConfig
import com.example.lynxshell.model.KeyboardBehavior
import com.example.lynxshell.model.LynxPageRequest
import com.example.lynxshell.model.PageOrientation
import org.json.JSONObject

/**
 * 把 Intent、深链、Explorer 本地地址和 Sparkling hybrid URL 统一转换成 LynxPageRequest。
 *
 * 兼容的典型参数别名：
 * - `hidden_nav` / `hide_nav_bar` / `hideNavigationBar`
 * - `orientation` / `screen_orientation`
 * - `initData` / `initialData` / `initial_data`
 * - `globalProps` / `global_props`
 */
object LynxRouteParser {
    private const val EXPLORER_LOCAL_PREFIX = "file://lynx?local://"

    fun parse(intent: Intent): Result<LynxPageRequest> = runCatching {
        intent.getStringExtra(LynxPageRequest.EXTRA_BUNDLE_URL)?.let {
            return@runCatching fromIntentExtras(intent).validated()
        }

        val data = requireNotNull(intent.data) { "Intent 缺少 Lynx 页面参数" }
        fromUri(data).validated()
    }

    /** Native Module 打开页面时使用；optionsJSON 必须是 JSON Object。 */
    fun fromBridge(url: String, optionsJson: String): LynxPageRequest {
        val options = if (optionsJson.isBlank()) JSONObject() else JSONObject(optionsJson)
        val base = if (url.contains("://")) {
            fromRawRoute(url)
        } else {
            defaultRequest(normalizeBundle(url))
        }
        return applyOptions(base, options).validated()
    }

    fun fromUri(uri: Uri): LynxPageRequest = fromRawRoute(uri.toString())

    private fun fromRawRoute(rawRoute: String): LynxPageRequest {
        if (rawRoute.startsWith(EXPLORER_LOCAL_PREFIX, ignoreCase = true)) {
            return requestFromExplorerLocal(rawRoute)
        }

        val uri = Uri.parse(rawRoute)
        val scheme = uri.scheme.orEmpty().lowercase()
        val query = parseEncodedQuery(uri.encodedQuery)

        if (scheme == "lynxshell" || (scheme == "hybrid" && uri.host == "lynxview_page")) {
            val rawBundle = first(query, "url", "bundle")
                ?.takeIf { it.isNotBlank() }
                ?: throw IllegalArgumentException("路由缺少 url 或 bundle 参数")
            return requestFromQuery(normalizeBundle(rawBundle), query)
        }

        if (scheme in setOf("assets", "https", "http")) {
            return requestFromQuery(rawRoute, query)
        }

        throw IllegalArgumentException("不支持的路由: $rawRoute")
    }

    /**
     * Explorer 的 `file://lynx?local://xxx.bundle?...` 不是标准 URL：第一个问号属于协议，
     * 第二个问号才开始承载页面参数，因此不能直接依赖 Uri.getQueryParameter。
     */
    private fun requestFromExplorerLocal(rawRoute: String): LynxPageRequest {
        val payload = rawRoute.substring(EXPLORER_LOCAL_PREFIX.length)
        val optionIndex = payload.indexOf('?')
        val encodedPath = if (optionIndex >= 0) payload.substring(0, optionIndex) else payload
        val encodedOptions = if (optionIndex >= 0) payload.substring(optionIndex + 1) else ""
        val path = Uri.decode(encodedPath).trim()
        require(path.isNotBlank()) { "Explorer 本地 Bundle 路径为空" }
        val bundle = EXPLORER_LOCAL_PREFIX + stripRelativePrefix(path)
        return requestFromQuery(bundle, parseEncodedQuery(encodedOptions))
    }

    private fun fromIntentExtras(intent: Intent): LynxPageRequest {
        // Bundle 默认 edge-to-edge 且不显示宿主 Toolbar；状态栏保留并透明覆盖在内容上。
        val fullscreen = intent.getBooleanExtra(LynxPageRequest.EXTRA_FULLSCREEN, true)
        val showToolbar = if (intent.hasExtra(LynxPageRequest.EXTRA_SHOW_TOOLBAR)) {
            intent.getBooleanExtra(LynxPageRequest.EXTRA_SHOW_TOOLBAR, !fullscreen)
        } else {
            !fullscreen
        }
        val hideStatusBar = if (intent.hasExtra(LynxPageRequest.EXTRA_HIDE_STATUS_BAR)) {
            intent.getBooleanExtra(LynxPageRequest.EXTRA_HIDE_STATUS_BAR, false)
        } else {
            false
        }

        return LynxPageRequest(
            bundleUrl = intent.getStringExtra(LynxPageRequest.EXTRA_BUNDLE_URL).orEmpty(),
            lynxAppId = intent.getStringExtra(LynxPageRequest.EXTRA_LYNX_APP_ID),
            bundleName = intent.getStringExtra(LynxPageRequest.EXTRA_BUNDLE_NAME),
            routeKey = intent.getStringExtra(LynxPageRequest.EXTRA_ROUTE_KEY).orEmpty(),
            title = intent.getStringExtra(LynxPageRequest.EXTRA_TITLE) ?: "Lynx",
            initDataJson = intent.getStringExtra(LynxPageRequest.EXTRA_INIT_DATA) ?: "{}",
            globalPropsJson = intent.getStringExtra(LynxPageRequest.EXTRA_GLOBAL_PROPS) ?: "{}",
            fullscreen = fullscreen,
            showToolbar = showToolbar,
            hideStatusBar = hideStatusBar,
            backGestureEnabled = intent.getBooleanExtra(
                LynxPageRequest.EXTRA_BACK_GESTURE_ENABLED,
                true,
            ),
            allowHttpInDebug = intent.getBooleanExtra(LynxPageRequest.EXTRA_ALLOW_HTTP, false),
            orientation = enumValueOrDefault(
                intent.getStringExtra(LynxPageRequest.EXTRA_ORIENTATION),
                PageOrientation.SYSTEM,
            ),
            keyboardBehavior = parseKeyboardBehavior(
                intent.getStringExtra(LynxPageRequest.EXTRA_KEYBOARD_BEHAVIOR),
            ),
            backgroundColor = intent.getStringExtra(LynxPageRequest.EXTRA_BACKGROUND_COLOR) ?: "#FFFFFF",
            widthPx = intent.optionalInt(LynxPageRequest.EXTRA_WIDTH),
            heightPx = intent.optionalInt(LynxPageRequest.EXTRA_HEIGHT),
            density = intent.optionalFloat(LynxPageRequest.EXTRA_DENSITY),
        )
    }

    private fun requestFromQuery(bundleUrl: String, query: Map<String, String>): LynxPageRequest {
        // 深链未声明 chrome 参数时同样采用纯 Lynx 全屏容器。
        val fullscreen = bool(first(query, "fullscreen"), true)
        val hiddenNavigation = bool(
            first(query, "hidden_nav", "hide_nav_bar", "hideNavigationBar"),
            false,
        )
        val explicitNavigation = first(query, "showNavigationBar", "showToolbar")
        val showToolbar = if (explicitNavigation != null) {
            !fullscreen && bool(explicitNavigation, true)
        } else {
            !fullscreen && !hiddenNavigation
        }
        val hideStatusBar = bool(
            first(query, "hide_status_bar", "hideStatusBar"),
            false,
        )

        // HTTPS 是独立的 Direct Remote 语义；即使调用方误带 OTA 字段，也不能进入本地
        // current/Manifest 链路。只有受控的 assets/local Bundle 才允许携带 appId。
        val isDirectRemote = LynxPageRequest.isRemoteBundleUrl(bundleUrl)
        val otaAppId = first(query, "lynxAppId", "appId", "lynx_app_id")
            ?.takeUnless { isDirectRemote }
            ?.trim()
            ?.takeIf { it.isNotBlank() }
        // Scheme 中传 appId + bundleName 时进入 OTA；没有 appId 仍保持原来的直加载语义。
        val otaBundleName = if (otaAppId != null) {
            first(query, "bundleName", "bundle_name")
                ?.trim()
                ?.takeIf { it.isNotBlank() }
                ?: bundleUrl
                    .takeUnless { LynxPageRequest.isRemoteBundleUrl(it) }
                    ?.removePrefix("assets://")
                    ?.removePrefix("bundles/")
        } else {
            null
        }

        return LynxPageRequest(
            bundleUrl = bundleUrl,
            lynxAppId = otaAppId?.takeIf { otaBundleName != null },
            bundleName = otaBundleName,
            routeKey = first(query, "routeKey", "route_key") ?: otaBundleName ?: bundleUrl,
            title = first(query, "title")?.takeIf { it.isNotBlank() } ?: "Lynx",
            initDataJson = first(query, "initData", "initialData", "initial_data") ?: "{}",
            // Playground 的导航、主题和容器示例都从 __globalProps.queryItems 读取路由参数。
            globalPropsJson = mergeQueryIntoGlobalProps(
                first(query, "globalProps", "global_props") ?: "{}",
                query,
            ),
            fullscreen = fullscreen,
            showToolbar = showToolbar,
            hideStatusBar = hideStatusBar,
            backGestureEnabled = bool(
                first(query, "backGestureEnabled", "back_gesture_enabled"),
                true,
            ),
            allowHttpInDebug = BuildConfig.DEBUG && bool(
                first(query, "allowHttpInDebug", "allow_http_in_debug"),
                false,
            ),
            orientation = parseOrientation(first(query, "orientation", "screen_orientation")),
            keyboardBehavior = parseKeyboardBehavior(
                first(query, "keyboardBehavior", "keyboard_behavior"),
            ),
            backgroundColor = normalizeColor(
                first(query, "backgroundColor", "background_color", "container_bg_color")
                    ?: "#FFFFFF",
            ),
            widthPx = first(query, "width", "width_px")?.toIntOrNull(),
            heightPx = first(query, "height", "height_px")?.toIntOrNull(),
            density = first(query, "density")?.toFloatOrNull()?.let { value ->
                // Explorer URL 中 density 通常表示 dpi；小于 10 时按 Android density 直接处理。
                if (value >= 10f) value / 160f else value
            },
        )
    }

    private fun applyOptions(base: LynxPageRequest, options: JSONObject): LynxPageRequest {
        val fullscreenOption = options.firstBoolean("fullscreen")
        val fullscreen = fullscreenOption ?: base.fullscreen

        var showToolbar = base.showToolbar
        if (fullscreenOption != null) {
            // 从全屏切回普通页面时恢复合理的原生导航默认值。
            showToolbar = if (fullscreen) false else if (base.fullscreen) true else base.showToolbar
        }
        options.firstBoolean("showNavigationBar", "showToolbar")?.let { visible ->
            showToolbar = !fullscreen && visible
        }
        options.firstBoolean("hidden_nav", "hide_nav_bar", "hideNavigationBar")?.let { hidden ->
            showToolbar = !fullscreen && !hidden
        }

        // fullscreen 只控制 edge-to-edge；是否隐藏状态栏必须由独立参数明确表达。
        var hideStatusBar = base.hideStatusBar
        options.firstBoolean("hideStatusBar", "hide_status_bar")?.let { hideStatusBar = it }

        val keyboardBehavior = options.firstString("keyboardBehavior", "keyboard_behavior")
            ?.let(::parseKeyboardBehavior)
            ?: base.keyboardBehavior

        val isDirectRemote = LynxPageRequest.isRemoteBundleUrl(base.bundleUrl)
        val appId = options.firstString("lynxAppId", "appId", "lynx_app_id")
            ?.trim()
            ?.takeIf { it.isNotBlank() }
            ?.takeUnless { isDirectRemote }
            ?: base.lynxAppId?.takeUnless { isDirectRemote }
        val requestedBundleName = options.firstString("bundleName", "bundle_name")
            ?.trim()
            ?.takeIf { it.isNotBlank() }
        val bundleName = if (isDirectRemote) {
            null
        } else if (requestedBundleName != null) {
            requestedBundleName
        } else if (base.bundleName != null) {
            base.bundleName
        } else if (
            appId != null && !LynxPageRequest.isRemoteBundleUrl(base.bundleUrl)
        ) {
            base.bundleUrl.substringAfterLast('/').substringBefore('?')
        } else {
            null
        }

        return base.copy(
            lynxAppId = appId?.takeIf { bundleName != null },
            bundleName = bundleName,
            routeKey = options.firstString("routeKey", "route_key")
                ?.takeIf { it.isNotBlank() }
                ?: base.routeKey,
            title = options.firstString("title")?.takeIf { it.isNotBlank() } ?: base.title,
            initDataJson = options.firstObjectJson(
                keys = arrayOf("initData", "initialData", "initial_data"),
                fallback = base.initDataJson,
            ),
            globalPropsJson = options.firstObjectJson(
                keys = arrayOf("globalProps", "global_props"),
                fallback = base.globalPropsJson,
            ),
            fullscreen = fullscreen,
            showToolbar = showToolbar,
            hideStatusBar = hideStatusBar,
            backGestureEnabled = options.firstBoolean(
                "backGestureEnabled",
                "back_gesture_enabled",
            ) ?: base.backGestureEnabled,
            allowHttpInDebug = BuildConfig.DEBUG && (
                options.firstBoolean("allowHttpInDebug", "allow_http_in_debug")
                    ?: base.allowHttpInDebug
                ),
            orientation = options.firstString("orientation", "screen_orientation")
                ?.let(::parseOrientation)
                ?: base.orientation,
            keyboardBehavior = keyboardBehavior,
            backgroundColor = normalizeColor(
                options.firstString(
                    "backgroundColor",
                    "background_color",
                    "container_bg_color",
                ) ?: base.backgroundColor,
            ),
            widthPx = options.firstNumber("width", "width_px")?.toInt() ?: base.widthPx,
            heightPx = options.firstNumber("height", "height_px")?.toInt() ?: base.heightPx,
            density = options.firstNumber("density")?.toFloat()?.let { value ->
                if (value >= 10f) value / 160f else value
            } ?: base.density,
        )
    }

    private fun defaultRequest(bundleUrl: String) = LynxPageRequest(bundleUrl = bundleUrl)

    private fun normalizeBundle(value: String): String {
        val trimmed = value.trim()
        if (trimmed.contains("://") || trimmed.startsWith(EXPLORER_LOCAL_PREFIX)) return trimmed
        val path = stripRelativePrefix(trimmed).trimStart('/')
        return if (path.startsWith("bundles/", ignoreCase = true)) {
            "assets://$path"
        } else {
            "assets://bundles/$path"
        }
    }

    private fun stripRelativePrefix(value: String): String {
        var result = value.replace('\\', '/')
        while (result.startsWith("./")) result = result.removePrefix("./")
        return result
    }

    private fun parseOrientation(value: String?): PageOrientation = when (value?.lowercase()) {
        "portrait", "vertical" -> PageOrientation.PORTRAIT
        "landscape", "horizontal" -> PageOrientation.LANDSCAPE
        else -> PageOrientation.SYSTEM
    }

    private fun parseKeyboardBehavior(value: String?): KeyboardBehavior = when (value?.trim()?.lowercase()) {
        "resize" -> KeyboardBehavior.RESIZE
        "pan" -> KeyboardBehavior.PAN
        "nothing", "none" -> KeyboardBehavior.NOTHING
        else -> KeyboardBehavior.SYSTEM
    }

    private fun normalizeColor(value: String): String =
        if (value.startsWith("#")) value else "#$value"

    private fun parseEncodedQuery(encodedQuery: String?): Map<String, String> {
        if (encodedQuery.isNullOrBlank()) return emptyMap()
        val result = linkedMapOf<String, String>()
        encodedQuery.split('&').forEach { part ->
            if (part.isBlank()) return@forEach
            val pieces = part.split('=', limit = 2)
            val key = Uri.decode(pieces[0])
            val value = Uri.decode(pieces.getOrElse(1) { "" })
            result[key] = value
        }
        return result
    }

    private fun first(query: Map<String, String>, vararg keys: String): String? =
        keys.firstNotNullOfOrNull(query::get)

    private fun bool(value: String?, fallback: Boolean): Boolean {
        if (value == null) return fallback
        return value == "1" || value.equals("true", ignoreCase = true) ||
            value.equals("yes", ignoreCase = true)
    }

    private fun mergeQueryIntoGlobalProps(
        globalPropsJson: String,
        query: Map<String, String>,
    ): String = JSONObject(globalPropsJson).apply {
        put("queryItems", JSONObject(query))
    }.toString()

    private fun JSONObject.firstValue(vararg keys: String): Any? {
        for (key in keys) {
            if (has(key) && !isNull(key)) return get(key)
        }
        return null
    }

    private fun JSONObject.firstString(vararg keys: String): String? =
        firstValue(*keys)?.let { value -> if (value is String) value else value.toString() }

    private fun JSONObject.firstNumber(vararg keys: String): Number? = when (val value = firstValue(*keys)) {
        is Number -> value
        is String -> value.toDoubleOrNull()
        else -> null
    }

    private fun JSONObject.firstBoolean(vararg keys: String): Boolean? = when (val value = firstValue(*keys)) {
        is Boolean -> value
        is Number -> value.toInt() != 0
        is String -> when {
            value == "1" || value.equals("true", true) || value.equals("yes", true) -> true
            value == "0" || value.equals("false", true) || value.equals("no", true) -> false
            else -> null
        }
        else -> null
    }

    private fun JSONObject.firstObjectJson(keys: Array<String>, fallback: String): String {
        return when (val value = firstValue(*keys)) {
            null -> fallback
            is JSONObject -> value.toString()
            is String -> value
            else -> throw IllegalArgumentException("${keys.first()} 必须是 JSON Object 或其字符串形式")
        }
    }

    private fun Intent.optionalInt(key: String): Int? = if (hasExtra(key)) getIntExtra(key, 0) else null
    private fun Intent.optionalFloat(key: String): Float? = if (hasExtra(key)) getFloatExtra(key, 0f) else null

    private inline fun <reified T : Enum<T>> enumValueOrDefault(value: String?, fallback: T): T =
        runCatching { enumValueOf<T>(value.orEmpty()) }.getOrDefault(fallback)
}
