package com.example.lynxcapacitormodule

import android.Manifest
import android.app.Activity
import android.app.Dialog
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.view.WindowManager
import android.view.accessibility.AccessibilityManager
import android.view.inputmethod.InputMethodManager
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import androidx.core.content.FileProvider
import androidx.core.view.WindowInsetsControllerCompat
import com.lynx.tasm.LynxView
import java.io.ByteArrayOutputStream
import java.io.File
import java.lang.ref.WeakReference
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.util.Locale
import java.util.concurrent.atomic.AtomicReference
import java.util.WeakHashMap
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener

/**
 * LynxCapacitorModule 的网络、系统和 UI 原生能力实现。
 *
 * 这里只调用 Android framework，不创建 Capacitor Bridge，也不依赖任何 Capacitor plugin。
 * 返回值是能力本身的业务对象；错误使用 error.code/error.message 表达，不在这里生成
 * success/data 回调 envelope。
 */
object NativeSystemCapabilities {
    private const val DEFAULT_CONNECT_TIMEOUT_MS = 10_000
    private const val DEFAULT_READ_TIMEOUT_MS = 15_000
    private const val MAX_HTTP_TIMEOUT_MS = 120_000
    private const val HTTP_MAX_RESPONSE_BYTES = 10 * 1024 * 1024
    // WindowInsets.Type 在 API 30 才公开；这些是同一组稳定 bit mask，避免 API 26-29 加载该类。
    private const val STATUS_BARS_TYPE = 1
    private const val NAVIGATION_BARS_TYPE = 2

    private val inAppBrowserDialog = AtomicReference<Dialog?>(null)
    private val inAppBrowserOwner = AtomicReference<WeakReference<Activity>?>(null)
    private val splashLock = Any()
    private val splashOverlays = WeakHashMap<Activity, View>()
    private val textZoomValues = WeakHashMap<Activity, Float>()

    /** Activity 销毁时释放当前 Module 创建的浏览器 Dialog 和 Splash 遮罩，避免 Window/View 泄漏。 */
    fun release(activity: Activity) {
        val cleanup = Runnable {
            val owner = inAppBrowserOwner.get()
            if (owner?.get() === activity && inAppBrowserOwner.compareAndSet(owner, null)) {
                inAppBrowserDialog.getAndSet(null)?.let { dialog -> runCatching { dialog.dismiss() } }
            }
            val overlay = synchronized(splashLock) { splashOverlays.remove(activity) }
            overlay?.let { view -> runCatching { (view.parent as? ViewGroup)?.removeView(view) } }
        }
        if (isMainThread()) cleanup.run() else runCatching { activity.runOnUiThread(cleanup) }
    }

    /**
     * 处理网络、系统和 UI 能力。
     *
     * 返回 null 表示 pluginId 不属于本能力域；属于本能力域但方法不能安全完成时，
     * 返回结构化错误对象。需要 Android UI 线程的能力不会从后台线程同步切回主线程，
     * 以免阻塞当前 Lynx dispatcher。
     */
    fun dispatch(activity: Activity, pluginId: String, methodName: String, options: JSONObject): JSONObject? {
        if (pluginId !in SUPPORTED_PLUGINS) return null

        return runCatching {
            when (pluginId) {
                "CapacitorHttp" -> http(activity, methodName, options)
                "CapacitorCookies" -> cookies(methodName, options)
                "Dialog" -> unsupported(pluginId, methodName, "当前同步 Lynx callback 无法等待原生用户输入")
                "ActionSheet" -> unsupported(pluginId, methodName, "当前同步 Lynx callback 无法等待原生选项选择")
                "Browser" -> browser(activity, methodName, options)
                "InAppBrowser" -> inAppBrowser(activity, methodName, options)
                "ScreenReader" -> screenReader(activity, methodName, options)
                "TextZoom" -> textZoom(activity, methodName, options)
                "Keyboard" -> keyboard(activity, methodName)
                "StatusBar" -> statusBar(activity, methodName, options)
                "SystemBars" -> systemBars(activity, methodName, options)
                "SafeArea" -> safeArea(activity, methodName, options)
                "SplashScreen" -> splashScreen(activity, methodName, options)
                "PrivacyScreen" -> privacyScreen(activity, methodName)
                "ScreenOrientation" -> screenOrientation(activity, methodName, options)
                "KeepAwake" -> keepAwake(activity, methodName)
                "Share" -> share(activity, methodName, options)
                else -> null
            }
        }.getOrElse { error -> nativeError(pluginId, methodName, error) }
    }

    private val SUPPORTED_PLUGINS = setOf(
        "CapacitorHttp",
        "CapacitorCookies",
        "Dialog",
        "ActionSheet",
        "Browser",
        "InAppBrowser",
        "ScreenReader",
        "TextZoom",
        "Keyboard",
        "StatusBar",
        "SystemBars",
        "SafeArea",
        "SplashScreen",
        "PrivacyScreen",
        "ScreenOrientation",
        "KeepAwake",
        "Share",
    )

    /** HttpURLConnection 是阻塞 API，只允许在非主线程执行。 */
    private fun http(activity: Activity, methodName: String, options: JSONObject): JSONObject {
        if (isMainThread()) {
            return unsupported("CapacitorHttp", methodName, "HttpURLConnection 需要后台线程，当前同步 dispatcher 在主线程")
        }

        val url = options.optString("url").trim()
        if (url.isEmpty()) return invalidArgument("CapacitorHttp", methodName, "url 不能为空")
        val parsedUrl = runCatching { URL(url) }.getOrNull()
        if (parsedUrl == null || parsedUrl.protocol.lowercase(Locale.US) !in setOf("http", "https")) {
            return invalidArgument("CapacitorHttp", methodName, "只支持 http/https URL")
        }

        val method = when (methodName) {
            "get" -> "GET"
            "post" -> "POST"
            "request" -> options.optString("method", "GET").trim().uppercase(Locale.US)
            else -> return unsupported("CapacitorHttp", methodName, "不支持的方法")
        }
        if (method !in HTTP_METHODS) {
            return invalidArgument("CapacitorHttp", methodName, "不支持的 HTTP method: $method")
        }

        val connectTimeout = timeout(options, "connectTimeout", DEFAULT_CONNECT_TIMEOUT_MS)
            ?: return invalidArgument("CapacitorHttp", methodName, "connectTimeout 必须是 0 到 $MAX_HTTP_TIMEOUT_MS 的毫秒数")
        val readTimeout = timeout(options, "readTimeout", DEFAULT_READ_TIMEOUT_MS)
            ?: return invalidArgument("CapacitorHttp", methodName, "readTimeout 必须是 0 到 $MAX_HTTP_TIMEOUT_MS 的毫秒数")
        val requestUrl = appendQueryParams(url, options.optJSONObject("params"), options.optBoolean("shouldEncodeUrlParams", true))
            ?: return invalidArgument("CapacitorHttp", methodName, "url 或 params 无法解析")

        var connection: HttpURLConnection? = null
        return try {
            connection = (URL(requestUrl).openConnection() as? HttpURLConnection)
                ?: return nativeError("CapacitorHttp", methodName, IllegalStateException("URL 不是 HttpURLConnection"))
            connection.requestMethod = method
            connection.connectTimeout = connectTimeout
            connection.readTimeout = readTimeout
            connection.instanceFollowRedirects = !options.optBoolean("disableRedirects", false)

            val headers = options.optJSONObject("headers")
            if (headers != null) {
                val keys = headers.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    val value = headers.opt(key)
                    if (value != null && value !== JSONObject.NULL) {
                        connection.setRequestProperty(key, value.toString())
                    }
                }
            }

            val body = requestBody(options.opt("data"), headers)
            if (body != null && method !in setOf("GET", "HEAD")) {
                connection.doOutput = true
                connection.outputStream.use { it.write(body) }
            }

            val status = connection.responseCode
            val responseBytes = readLimited(if (status >= 400) connection.errorStream else connection.inputStream)
            val responseHeaders = responseHeaders(connection.headerFields)
            val result = JSONObject()
                .put("status", status)
                .put("headers", responseHeaders)
                .put("url", connection.url.toString())
            result.put("data", responseData(responseBytes, options.optString("responseType")))
            result
        } catch (error: Exception) {
            nativeError("CapacitorHttp", methodName, error)
        } finally {
            connection?.disconnect()
        }
    }

    private val HTTP_METHODS = setOf("GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS")

    private fun timeout(options: JSONObject, key: String, default: Int): Int? {
        if (!options.has(key) || options.isNull(key)) return default
        val value = options.optDouble(key, Double.NaN)
        return if (value.isFinite() && value >= 0 && value <= MAX_HTTP_TIMEOUT_MS) value.toInt() else null
    }

    private fun appendQueryParams(url: String, params: JSONObject?, encode: Boolean): String? {
        if (params == null || params.length() == 0) return url.takeIf { runCatching { URL(it) }.isSuccess }
        val query = StringBuilder()
        val keys = params.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            val value = params.opt(key)
            val values = if (value is JSONArray) {
                (0 until value.length()).map { value.opt(it) }
            } else {
                listOf(value)
            }
            values.forEach { item ->
                if (query.isNotEmpty()) query.append('&')
                query.append(if (encode) encodeQueryPart(key) else key)
                query.append('=')
                query.append(if (encode) encodeQueryPart(jsonScalar(item)) else jsonScalar(item))
            }
        }
        val fragmentIndex = url.indexOf('#')
        val fragment = if (fragmentIndex >= 0) url.substring(fragmentIndex) else ""
        val withoutFragment = if (fragmentIndex >= 0) url.substring(0, fragmentIndex) else url
        val separator = when {
            query.isEmpty() -> ""
            withoutFragment.contains('?') && (withoutFragment.endsWith('?') || withoutFragment.endsWith('&')) -> ""
            withoutFragment.contains('?') -> "&"
            else -> "?"
        }
        val result = withoutFragment + separator + query + fragment
        return result.takeIf { runCatching { URL(it) }.isSuccess }
    }

    private fun encodeQueryPart(value: String): String = URLEncoder.encode(value, StandardCharsets.UTF_8.name())

    private fun jsonScalar(value: Any?): String = when {
        value == null || value === JSONObject.NULL -> ""
        else -> value.toString()
    }

    private fun requestBody(data: Any?, headers: JSONObject?): ByteArray? {
        if (data == null || data === JSONObject.NULL) return null
        val contentType = headers?.optString("Content-Type", headers.optString("content-type", ""))
            ?.lowercase(Locale.US)
            .orEmpty()
        val text = when {
            data is String -> data
            contentType.contains("application/x-www-form-urlencoded") && data is JSONObject -> formBody(data)
            data is JSONObject || data is JSONArray -> data.toString()
            else -> data.toString()
        }
        return text.toByteArray(StandardCharsets.UTF_8)
    }

    private fun formBody(data: JSONObject): String {
        val parts = mutableListOf<String>()
        val keys = data.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            val value = data.opt(key)
            if (value is JSONArray) {
                for (index in 0 until value.length()) {
                    parts += "${encodeQueryPart(key)}=${encodeQueryPart(jsonScalar(value.opt(index)))}"
                }
            } else {
                parts += "${encodeQueryPart(key)}=${encodeQueryPart(jsonScalar(value))}"
            }
        }
        return parts.joinToString("&")
    }

    private fun readLimited(input: InputStream?): ByteArray {
        if (input == null) return ByteArray(0)
        input.use { stream ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            var total = 0
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                total += count
                if (total > HTTP_MAX_RESPONSE_BYTES) {
                    throw IllegalStateException("HTTP response 超过 ${HTTP_MAX_RESPONSE_BYTES / (1024 * 1024)} MB 限制")
                }
                output.write(buffer, 0, count)
            }
            return output.toByteArray()
        }
    }

    private fun responseHeaders(fields: Map<String?, List<String>?>?): JSONObject {
        val result = JSONObject()
        fields?.forEach { (name, values) ->
            if (name == null || values.isNullOrEmpty()) return@forEach
            val nonNullValues = values.filterNotNull()
            if (nonNullValues.isEmpty()) return@forEach
            if (nonNullValues.size == 1) {
                result.put(name, nonNullValues.first())
            } else {
                result.put(name, JSONArray(nonNullValues))
            }
        }
        return result
    }

    private fun responseData(bytes: ByteArray, responseType: String): Any {
        if (responseType.equals("arraybuffer", true) || responseType.equals("blob", true)) {
            return android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)
        }
        val text = bytes.toString(StandardCharsets.UTF_8)
        if (responseType.equals("text", true) || responseType.equals("document", true) || text.isBlank()) return text
        return runCatching { JSONTokener(text).nextValue() }.getOrDefault(text)
    }

    private fun cookies(methodName: String, options: JSONObject): JSONObject {
        val url = options.optString("url").trim()
        if (methodName != "clearAllCookies" && url.isEmpty()) {
            return invalidArgument("CapacitorCookies", methodName, "url 不能为空")
        }
        val manager = runCatching { CookieManager.getInstance() }.getOrElse {
            return unsupported("CapacitorCookies", methodName, "当前 Android 设备没有可用的 CookieManager")
        }
        return runCatching {
            when (methodName) {
                "setCookie" -> {
                    val key = options.optString("key").trim()
                    if (key.isEmpty()) return invalidArgument("CapacitorCookies", methodName, "key 不能为空")
                    val cookie = buildCookie(options, key)
                    manager.setCookie(url, cookie)
                    manager.flush()
                    JSONObject().put("saved", true)
                }
                "getCookies" -> {
                    val result = JSONObject()
                    val raw = manager.getCookie(url).orEmpty()
                    val parsed = JSONObject()
                    raw.split(';').forEach { pair ->
                        val separator = pair.indexOf('=')
                        if (separator > 0) {
                            parsed.put(pair.substring(0, separator).trim(), pair.substring(separator + 1).trim())
                        }
                    }
                    result.put("cookies", parsed)
                }
                "clearAllCookies" -> {
                    manager.removeAllCookies(null)
                    manager.flush()
                    JSONObject().put("cleared", true)
                }
                else -> unsupported("CapacitorCookies", methodName, "不支持的方法")
            }
        }.getOrElse { error -> nativeError("CapacitorCookies", methodName, error) }
    }

    private fun buildCookie(options: JSONObject, key: String): String = buildString {
        append(key)
        append('=')
        append(options.optString("value", ""))
        options.optString("path").takeIf(String::isNotBlank)?.let { append("; Path=").append(it) }
        options.optString("domain").takeIf(String::isNotBlank)?.let { append("; Domain=").append(it) }
        options.optString("expires").takeIf(String::isNotBlank)?.let { append("; Expires=").append(it) }
        if (options.has("maxAge") && !options.isNull("maxAge")) append("; Max-Age=").append(options.optLong("maxAge"))
        if (options.optBoolean("secure", false)) append("; Secure")
        if (options.optBoolean("httpOnly", false)) append("; HttpOnly")
        options.optString("sameSite").takeIf(String::isNotBlank)?.let { append("; SameSite=").append(it) }
    }

    private fun browser(activity: Activity, methodName: String, options: JSONObject): JSONObject {
        return when (methodName) {
            "open" -> onUiThread("Browser", methodName) {
                val url = requireUrl("Browser", methodName, options) ?: return@onUiThread invalidArgument("Browser", methodName, "url 不能为空")
                val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                if (intent.resolveActivity(activity.packageManager) == null) {
                    unsupported("Browser", methodName, "没有可处理该 URL 的外部应用")
                } else {
                    activity.startActivity(intent)
                    JSONObject().put("opened", true).put("mode", "external")
                }
            }
            "close" -> unsupported("Browser", methodName, "ACTION_VIEW 启动的外部浏览器不受当前 Activity 控制")
            else -> unsupported("Browser", methodName, "不支持的方法")
        }
    }

    private fun inAppBrowser(activity: Activity, methodName: String, options: JSONObject): JSONObject {
        return when (methodName) {
            "openInWebView" -> onUiThread("InAppBrowser", methodName) {
                val url = requireUrl("InAppBrowser", methodName, options)
                    ?: return@onUiThread invalidArgument("InAppBrowser", methodName, "url 不能为空")
                inAppBrowserDialog.getAndSet(null)?.dismiss()
                inAppBrowserOwner.set(null)
                val webView = WebView(activity)
                webView.settings.javaScriptEnabled = options.optBoolean("enableJavaScript", true)
                webView.settings.domStorageEnabled = options.optBoolean("enableDomStorage", true)
                webView.webViewClient = object : WebViewClient() {
                    @Suppress("DEPRECATION")
                    override fun shouldOverrideUrlLoading(view: WebView, url: String): Boolean = false

                    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean = false
                }
                val dialog = Dialog(activity)
                val owner = WeakReference(activity)
                dialog.requestWindowFeature(Window.FEATURE_NO_TITLE)
                dialog.setContentView(FrameLayout(activity).apply {
                    addView(webView, FrameLayout.LayoutParams(-1, -1))
                })
                dialog.setOnDismissListener {
                    webView.stopLoading()
                    webView.destroy()
                    if (inAppBrowserDialog.compareAndSet(dialog, null)) {
                        inAppBrowserOwner.compareAndSet(owner, null)
                    }
                }
                dialog.setOnShowListener {
                    dialog.window?.setLayout(
                        WindowManager.LayoutParams.MATCH_PARENT,
                        WindowManager.LayoutParams.MATCH_PARENT,
                    )
                }
                inAppBrowserOwner.set(owner)
                inAppBrowserDialog.set(dialog)
                dialog.show()
                webView.loadUrl(url)
                JSONObject().put("opened", true).put("mode", "native-webview")
            }
            "close" -> onUiThread("InAppBrowser", methodName) {
                val dialog = inAppBrowserDialog.getAndSet(null)
                inAppBrowserOwner.set(null)
                val wasOpen = dialog != null
                dialog?.dismiss()
                JSONObject().put("closed", wasOpen)
            }
            else -> unsupported("InAppBrowser", methodName, "不支持的方法")
        }
    }

    private fun screenReader(activity: Activity, methodName: String, options: JSONObject): JSONObject {
        val manager = activity.getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager
            ?: return unsupported("ScreenReader", methodName, "AccessibilityManager 不可用")
        return when (methodName) {
            "isEnabled" -> JSONObject().put("value", manager.isEnabled)
            "speak" -> onUiThread("ScreenReader", methodName) {
                val value = options.optString("value").trim()
                if (value.isEmpty()) return@onUiThread invalidArgument("ScreenReader", methodName, "value 不能为空")
                if (!manager.isEnabled) {
                    return@onUiThread unsupported("ScreenReader", methodName, "系统无障碍服务未开启，无法朗读")
                }
                val view = activity.window.decorView
                if (!view.isAttachedToWindow) return@onUiThread unsupported("ScreenReader", methodName, "当前 Activity 没有附着的原生视图")
                view.announceForAccessibility(value)
                JSONObject().put("spoken", true)
            }
            else -> unsupported("ScreenReader", methodName, "不支持的方法")
        }
    }

    private fun textZoom(activity: Activity, methodName: String, options: JSONObject): JSONObject {
        return when (methodName) {
            "getPreferred" -> JSONObject().put("value", activity.resources.configuration.fontScale.toDouble())
            "get" -> JSONObject().put(
                "value",
                textZoomValues[activity]?.toDouble() ?: activity.resources.configuration.fontScale.toDouble(),
            )
            "set" -> {
                val value = options.optDouble("value", Double.NaN)
                when {
                    !value.isFinite() || value <= 0.0 || value > 5.0 ->
                        invalidArgument("TextZoom", methodName, "value 必须是大于 0 且不超过 5 的有限数字")
                    findLynxViews(activity).isEmpty() ->
                        unsupported("TextZoom", methodName, "当前 Activity 没有可更新的 LynxView")
                    else -> {
                        val views = findLynxViews(activity)
                        views.forEach { it.updateFontScale(value.toFloat()) }
                        textZoomValues[activity] = value.toFloat()
                        JSONObject().put("value", value).put("updatedViews", views.size)
                    }
                }
            }
            else -> unsupported("TextZoom", methodName, "不支持的方法")
        }
    }

    private fun findLynxViews(activity: Activity): List<LynxView> {
        val result = mutableListOf<LynxView>()
        fun visit(view: View) {
            if (view is LynxView) result += view
            if (view is ViewGroup) {
                for (index in 0 until view.childCount) visit(view.getChildAt(index))
            }
        }
        visit(activity.window.decorView)
        return result
    }

    private fun keyboard(activity: Activity, methodName: String): JSONObject = when (methodName) {
        "getResizeMode" -> {
            val mode = activity.window.attributes.softInputMode and WindowManager.LayoutParams.SOFT_INPUT_MASK_ADJUST
            JSONObject().put("mode", when (mode) {
                WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE -> "resize"
                WindowManager.LayoutParams.SOFT_INPUT_ADJUST_PAN -> "pan"
                WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING -> "nothing"
                else -> "native"
            })
        }
        "setStyle" -> unsupported("Keyboard", methodName, "Android 输入法样式由当前 IME 控制，Module 无法安全设置")
        "hide" -> onUiThread("Keyboard", methodName) {
            val manager = activity.getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
                ?: return@onUiThread unsupported("Keyboard", methodName, "InputMethodManager 不可用")
            val target = activity.currentFocus ?: activity.window.decorView
            JSONObject().put("hidden", manager.hideSoftInputFromWindow(target.windowToken, 0))
        }
        else -> unsupported("Keyboard", methodName, "不支持的方法")
    }

    private fun splashScreen(activity: Activity, methodName: String, options: JSONObject): JSONObject = onUiThread("SplashScreen", methodName) {
        val root = (activity.findViewById(android.R.id.content) as? ViewGroup)
            ?: (activity.window.decorView as? ViewGroup)
            ?: return@onUiThread unsupported("SplashScreen", methodName, "当前 Activity 没有可用内容层")
        when (methodName) {
            "show" -> {
                val existing = synchronized(splashLock) { splashOverlays[activity] }
                if (existing?.parent != null) {
                    return@onUiThread JSONObject().put("visible", true).put("shown", false)
                }
                val background = runCatching {
                    Color.parseColor(options.optString("backgroundColor", "#101828"))
                }.getOrDefault(Color.rgb(16, 24, 40))
                val overlay = FrameLayout(activity).apply {
                    setBackgroundColor(background)
                    // 遮罩是视觉层；hide 调用仍需能从 Lynx 页面穿透到 Module。
                    isClickable = false
                    isFocusable = false
                    contentDescription = options.optString("contentDescription", "Splash Screen")
                    elevation = 100f
                }
                root.addView(overlay, ViewGroup.LayoutParams(-1, -1))
                synchronized(splashLock) { splashOverlays[activity] = overlay }
                JSONObject().put("visible", true).put("shown", true)
            }
            "hide" -> {
                val overlay = synchronized(splashLock) { splashOverlays.remove(activity) }
                overlay?.let { root.removeView(it) }
                JSONObject().put("visible", false).put("hidden", true)
            }
            else -> unsupported("SplashScreen", methodName, "不支持的方法")
        }
    }

    private fun statusBar(activity: Activity, methodName: String, options: JSONObject): JSONObject = when (methodName) {
        "getInfo" -> JSONObject()
            .put("visible", isBarVisible(activity, STATUS_BARS_TYPE))
            .put("style", currentBarStyle(activity))
        "setStyle" -> onUiThread("StatusBar", methodName) { setBarStyle(activity, options.optString("style", "DEFAULT")) }
        "hide" -> onUiThread("StatusBar", methodName) {
            setBarVisible(activity, STATUS_BARS_TYPE, false)
            JSONObject().put("visible", false)
        }
        "show" -> onUiThread("StatusBar", methodName) {
            setBarVisible(activity, STATUS_BARS_TYPE, true)
            JSONObject().put("visible", true)
        }
        else -> unsupported("StatusBar", methodName, "不支持的方法")
    }

    private fun systemBars(activity: Activity, methodName: String, options: JSONObject): JSONObject = when (methodName) {
        "setStyle" -> onUiThread("SystemBars", methodName) { setBarStyle(activity, options.optString("style", "DEFAULT")) }
        else -> unsupported("SystemBars", methodName, "不支持的方法")
    }

    private fun safeArea(activity: Activity, methodName: String, options: JSONObject): JSONObject = when (methodName) {
        "setSystemBarsStyle" -> onUiThread("SafeArea", methodName) { setBarStyle(activity, options.optString("style", "DEFAULT")) }
        "hideSystemBars" -> onUiThread("SafeArea", methodName) {
            setSafeAreaBars(activity, options.optString("type", "StatusBar"), false)
        }
        "showSystemBars" -> onUiThread("SafeArea", methodName) {
            setSafeAreaBars(activity, options.optString("type", "StatusBar"), true)
        }
        else -> unsupported("SafeArea", methodName, "不支持的方法")
    }

    private fun setSafeAreaBars(activity: Activity, type: String, visible: Boolean): JSONObject {
        val normalized = type.lowercase(Locale.US)
        val mask = when {
            normalized.contains("navigation") -> NAVIGATION_BARS_TYPE
            normalized.contains("system") -> STATUS_BARS_TYPE or NAVIGATION_BARS_TYPE
            normalized.contains("status") -> STATUS_BARS_TYPE
            else -> return invalidArgument("SafeArea", "${if (visible) "showSystemBars" else "hideSystemBars"}", "不支持的 system bar 类型: $type")
        }
        setBarVisible(activity, mask, visible)
        return JSONObject().put("visible", visible).put("type", type)
    }

    private fun setBarStyle(activity: Activity, style: String): JSONObject {
        val normalized = style.uppercase(Locale.US)
        // Android 15/targetSdk 35+ 强制 edge-to-edge 后，直接改 systemUiVisibility
        // 不能可靠地改变系统栏图标；必须通过 WindowInsetsController 设置真实外观。
        val controller = WindowInsetsControllerCompat(activity.window, activity.window.decorView)
        val lightIcons = normalized == "DARK"
        controller.isAppearanceLightStatusBars = lightIcons
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            controller.isAppearanceLightNavigationBars = lightIcons
        }
        // API 30+ 再用 framework controller 写一次，避免某些厂商在 edge-to-edge
        // 窗口上只更新 compat 状态而没有把 appearance 下发给 System UI。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val statusAppearance = if (lightIcons) {
                android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
            } else {
                0
            }
            val navigationAppearance = if (lightIcons) {
                android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS
            } else {
                0
            }
            activity.window.insetsController?.setSystemBarsAppearance(
                statusAppearance or navigationAppearance,
                android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or
                    android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
            )
        }
        val applied = WindowInsetsControllerCompat(activity.window, activity.window.decorView)
            .isAppearanceLightStatusBars == lightIcons
        return JSONObject()
            .put("style", normalized)
            .put("statusBarIcons", if (lightIcons) "dark" else "light")
            .put("applied", applied)
    }

    private fun currentBarStyle(activity: Activity): String = if (
        WindowInsetsControllerCompat(activity.window, activity.window.decorView).isAppearanceLightStatusBars
    ) "DARK" else "LIGHT"

    private fun isBarVisible(activity: Activity, type: Int): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return activity.window.insetsController?.let { controller ->
                activity.window.decorView.rootWindowInsets?.isVisible(type) ?: true
            } ?: true
        }
        @Suppress("DEPRECATION")
        val flags = activity.window.decorView.systemUiVisibility
        return if (type == STATUS_BARS_TYPE) {
            activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_FULLSCREEN == 0 &&
                flags and View.SYSTEM_UI_FLAG_FULLSCREEN == 0
        } else {
            flags and View.SYSTEM_UI_FLAG_HIDE_NAVIGATION == 0
        }
    }

    private fun setBarVisible(activity: Activity, type: Int, visible: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            activity.window.insetsController?.let { controller ->
                if (visible) controller.show(type) else controller.hide(type)
            }
            return
        }
        @Suppress("DEPRECATION")
        var flags = activity.window.decorView.systemUiVisibility
        val status = type and STATUS_BARS_TYPE != 0
        val navigation = type and NAVIGATION_BARS_TYPE != 0
        if (status) flags = if (visible) flags and View.SYSTEM_UI_FLAG_FULLSCREEN.inv() else flags or View.SYSTEM_UI_FLAG_FULLSCREEN
        if (navigation) flags = if (visible) flags and View.SYSTEM_UI_FLAG_HIDE_NAVIGATION.inv() else flags or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
        activity.window.decorView.systemUiVisibility = flags
    }

    private fun privacyScreen(activity: Activity, methodName: String): JSONObject = when (methodName) {
        "isEnabled" -> JSONObject().put("value", activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0)
        "enable" -> {
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            JSONObject().put("value", true)
        }
        "disable" -> {
            activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            JSONObject().put("value", false)
        }
        else -> unsupported("PrivacyScreen", methodName, "不支持的方法")
    }

    private fun screenOrientation(activity: Activity, methodName: String, options: JSONObject): JSONObject = when (methodName) {
        "orientation" -> JSONObject().put("type", currentOrientation(activity))
        "lock" -> onUiThread("ScreenOrientation", methodName) {
            val value = options.optString("orientation", "portrait").trim().lowercase(Locale.US)
            val requested = orientationConstant(value)
                ?: return@onUiThread invalidArgument("ScreenOrientation", methodName, "不支持的 orientation: $value")
            activity.requestedOrientation = requested
            JSONObject().put("locked", true).put("orientation", value)
        }
        "unlock" -> onUiThread("ScreenOrientation", methodName) {
            activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            JSONObject().put("locked", false)
        }
        else -> unsupported("ScreenOrientation", methodName, "不支持的方法")
    }

    private fun currentOrientation(activity: Activity): String = when (activity.resources.configuration.orientation) {
        android.content.res.Configuration.ORIENTATION_LANDSCAPE -> "landscape"
        android.content.res.Configuration.ORIENTATION_PORTRAIT -> "portrait"
        else -> "unknown"
    }

    private fun orientationConstant(value: String): Int? = when (value) {
        "portrait", "portrait-primary" -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        "portrait-secondary" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT else ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        "landscape", "landscape-primary" -> ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        "landscape-secondary" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE else ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        "any", "full-sensor", "fulluser" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR2) ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR else ActivityInfo.SCREEN_ORIENTATION_SENSOR
        "natural" -> ActivityInfo.SCREEN_ORIENTATION_NOSENSOR
        else -> null
    }

    private fun keepAwake(activity: Activity, methodName: String): JSONObject = when (methodName) {
        "isSupported" -> JSONObject().put("value", true)
        "isKeptAwake" -> JSONObject().put("value", activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON != 0)
        "keepAwake" -> onUiThread("KeepAwake", methodName) {
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            JSONObject().put("value", true)
        }
        "allowSleep" -> onUiThread("KeepAwake", methodName) {
            activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            JSONObject().put("value", false)
        }
        else -> unsupported("KeepAwake", methodName, "不支持的方法")
    }

    private fun share(activity: Activity, methodName: String, options: JSONObject): JSONObject = when (methodName) {
        "canShare" -> JSONObject().put(
            "value",
            Intent(Intent.ACTION_SEND).apply { type = "text/plain" }.resolveActivity(activity.packageManager) != null,
        )
        "share" -> onUiThread("Share", methodName) {
            val text = options.optString("text").trim()
            val url = options.optString("url").trim()
            val files = fileSources(options)
            val attachmentSources = buildList {
                files.forEach(::add)
                if (url.startsWith("file:", true) || url.startsWith("content:", true)) add(url)
            }
            if (text.isEmpty() && url.isEmpty() && attachmentSources.isEmpty()) {
                return@onUiThread invalidArgument("Share", methodName, "text、HTTP(S) url 或 files 至少提供一个")
            }
            val attachments = attachmentSources.map { source ->
                shareableUri(activity, source)
                    ?: return@onUiThread invalidArgument("Share", methodName, "无法读取分享文件: $source")
            }
            val httpUrlText = url.takeIf {
                it.isNotEmpty() && !it.startsWith("file:", true) && !it.startsWith("content:", true)
            }
            val sharedText = listOfNotNull(text.takeIf(String::isNotEmpty), httpUrlText).joinToString("\n")
            val send = Intent(if (attachments.size > 1) Intent.ACTION_SEND_MULTIPLE else Intent.ACTION_SEND).apply {
                type = options.optString("mimeType", "text/plain")
                if (sharedText.isNotEmpty()) putExtra(Intent.EXTRA_TEXT, sharedText)
                options.optString("title").takeIf(String::isNotEmpty)?.let { putExtra(Intent.EXTRA_TITLE, it) }
                when (attachments.size) {
                    1 -> putExtra(Intent.EXTRA_STREAM, attachments.single())
                    else -> putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(attachments))
                }
                if (attachments.isNotEmpty()) {
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    clipData = ClipData.newRawUri("lynx-share", attachments.first())
                }
            }
            if (send.resolveActivity(activity.packageManager) == null) return@onUiThread unsupported("Share", methodName, "没有可用的分享 Activity")
            activity.startActivity(Intent.createChooser(send, options.optString("dialogTitle").takeIf(String::isNotEmpty)))
            JSONObject().put("shared", true).put("fileCount", attachments.size)
        }
        else -> unsupported("Share", methodName, "不支持的方法")
    }

    private fun fileSources(options: JSONObject): List<String> {
        val result = mutableListOf<String>()
        options.optJSONArray("files")?.let { files ->
            for (index in 0 until files.length()) {
                when (val value = files.opt(index)) {
                    is String -> value.trim().takeIf(String::isNotEmpty)?.let(result::add)
                    is JSONObject -> firstNonBlank(value, "path", "uri")?.let(result::add)
                }
            }
        }
        return result
    }

    private fun firstNonBlank(options: JSONObject, vararg keys: String): String? =
        keys.asSequence()
            .map { key -> options.optString(key).trim() }
            .firstOrNull(String::isNotEmpty)

    private fun shareableUri(activity: Activity, source: String): Uri? {
        val parsed = Uri.parse(source)
        return when (parsed.scheme?.lowercase(Locale.US)) {
            "content" -> parsed
            "file" -> privateShareUri(activity, parsed.path ?: return null)
            null -> privateShareUri(activity, source)
            else -> null
        }
    }

    private fun privateShareUri(activity: Activity, rawPath: String): Uri? {
        val candidate = runCatching { File(rawPath).canonicalFile }.getOrNull() ?: return null
        val roots = listOfNotNull(
            activity.cacheDir,
            activity.filesDir,
            activity.externalCacheDir,
            activity.getExternalFilesDir(null),
        ).mapNotNull { runCatching { it.canonicalFile }.getOrNull() }
        if (roots.none { isWithin(candidate, it) } || !candidate.isFile) return null
        return runCatching {
            FileProvider.getUriForFile(activity, NativeFileProviderContract.authority(activity), candidate)
        }.getOrNull()
    }

    private fun isWithin(file: File, root: File): Boolean =
        file == root || file.path.startsWith(root.path + File.separator)

    private fun requireUrl(pluginId: String, methodName: String, options: JSONObject): String? {
        val value = options.optString("url").trim()
        return value.takeIf { it.isNotEmpty() && runCatching { Uri.parse(it) }.isSuccess }
    }

    private fun onUiThread(pluginId: String, methodName: String, block: () -> JSONObject): JSONObject {
        if (!isMainThread()) {
            return unsupported(pluginId, methodName, "该 Android API 需要主线程，当前同步 dispatcher 未切线程")
        }
        return block()
    }

    private fun isMainThread(): Boolean = Looper.myLooper() == Looper.getMainLooper()

    private fun unsupported(pluginId: String, methodName: String, message: String): JSONObject = errorResult(
        "UNSUPPORTED",
        "$pluginId.$methodName: $message",
    )

    private fun invalidArgument(pluginId: String, methodName: String, message: String): JSONObject = errorResult(
        "INVALID_ARGUMENT",
        "$pluginId.$methodName: $message",
    )

    private fun nativeError(pluginId: String, methodName: String, error: Throwable): JSONObject = errorResult(
        "NATIVE_ERROR",
        "$pluginId.$methodName: ${error.message ?: "Android native call failed"}",
    )

    private fun errorResult(code: String, message: String): JSONObject = JSONObject()
        .put("error", JSONObject().put("code", code).put("message", message))
}
