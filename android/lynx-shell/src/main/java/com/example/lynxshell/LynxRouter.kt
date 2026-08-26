package com.example.lynxshell

import android.app.Application
import android.content.Context
import com.example.lynxshell.bridge.LynxRouterMessageHandler
import com.example.lynxshell.bridge.ShellMessageHub
import com.example.lynxshell.ota.ActivityBundleRuntime
import com.example.lynxshell.ota.EmbeddedBundleRuntime
import com.example.lynxshell.routing.LynxNavigationOptions
import com.example.lynxshell.routing.LynxNavigationResult
import com.example.lynxshell.routing.LynxNavigator
import com.example.lynxshell.routing.LynxRouteParser
import org.json.JSONObject

/**
 * Android 三端统一门面。
 *
 * Android 的 Native Page Stack 承载仍然是“一页一个 LynxShellActivity”（Activity-first），
 * 这里只把调用面收敛成与 iOS/HarmonyOS 相同的 `install/open/pop` 语义。业务不需要知道
 * Activity 的 Intent extra、Registry 或 Provider 细节，也不需要预注册 routeId。
 */
object LynxRouter {
    /** Debug Sample 的一次性首屏故障注入；Release 构建不会消费该标记。 */
    @JvmStatic
    fun debugFailNextFirstScreen() {
        if (BuildConfig.DEBUG) LynxDebugFaults.failNextFirstScreen = true
    }

    internal fun consumeDebugFirstScreenFailure(): Boolean {
        if (!BuildConfig.DEBUG) return false
        return LynxDebugFaults.consumeFirstScreenFailure()
    }

    /** Application.onCreate 中调用一次；Runtime 初始化本身幂等。 */
    fun install(
        application: Application,
        activityBundleRuntime: ActivityBundleRuntime? = null,
    ) {
        LynxShell.initialize(application)
        val runtime = activityBundleRuntime ?: EmbeddedBundleRuntime(application)
        LynxShell.installActivityBundleRuntime(runtime)
        runtime.onApplicationStarted()
    }

    /**
     * 一体化 OTA 入口：三方只需要依赖 Router AAR 并提供配置，不再单独引入 OTA JAR 或实现
     * ActivityBundleRuntime。Router 内部负责生命周期同步、按 appId 的 Bundle 准备和回滚。
     */
    fun install(
        application: Application,
        otaConfig: com.example.lynxshell.ota.LynxOtaConfig,
    ): com.example.lynxshell.ota.LynxOtaRuntime {
        val runtime = com.example.lynxshell.ota.LynxOtaRuntime(application, otaConfig)
        install(application, runtime)
        return runtime
    }

    /**
     * 宿主回到前台时调用一次；OTA 适配器会异步刷新全量 appId，普通适配器无需处理。
     */
    fun onApplicationForeground() {
        LynxShell.activityBundleRuntime()?.onApplicationForeground()
    }

    /**
     * 用户主动刷新 OTA；同步完成后回调，页面容器可以重新读取已经提交的 current。
     * Tab 切换不会调用此方法，因此不会因为切换 Tab 重复访问网络。
     */
    fun refreshAllOtaBundles(onComplete: (success: Boolean) -> Unit = {}) {
        val runtime = LynxShell.activityBundleRuntime()
        if (runtime == null) {
            onComplete(false)
        } else {
            runtime.refreshAllBundles(onComplete)
        }
    }

    /** 按 appId 直接删除 Router 内置 OTA 的全部下载 Bundle；只适合诊断/验收入口。 */
    fun deleteOtaBundles(
        lynxAppId: String,
        onComplete: (success: Boolean, message: String?) -> Unit = { _, _ -> },
    ) {
        require(lynxAppId.isNotBlank()) { "lynxAppId 不能为空" }
        val runtime = LynxShell.activityBundleRuntime()
        if (runtime is com.example.lynxshell.ota.LynxOtaRuntime) {
            runtime.deleteBundles(lynxAppId, onComplete)
        } else {
            onComplete(false, "当前没有安装 Router OTA runtime")
        }
    }

    /** 直接删除 Router 内置 OTA 的全部 appId 下载 Bundle；embedded 描述仍保留。 */
    fun deleteAllOtaBundles(onComplete: (success: Boolean, message: String?) -> Unit = { _, _ -> }) {
        val runtime = LynxShell.activityBundleRuntime()
        if (runtime is com.example.lynxshell.ota.LynxOtaRuntime) {
            runtime.deleteAllBundles(onComplete)
        } else {
            onComplete(false, "当前没有安装 Router OTA runtime")
        }
    }

    /** 兼容旧诊断入口；语义仍然是直接删除全部下载内容。 */
    fun clearOtaCache(onComplete: (success: Boolean, message: String?) -> Unit = { _, _ -> }) {
        deleteAllOtaBundles(onComplete)
    }

    /** 运行时替换 OTA 适配器；适合宿主完成环境配置后再安装。 */
    fun installActivityBundleRuntime(runtime: ActivityBundleRuntime?) {
        LynxShell.installActivityBundleRuntime(runtime)
    }

    /** 向宿主注入“回业务主页”的实现。 */
    fun installAppHomeHandler(handler: com.example.lynxshell.routing.AppHomeHandler) {
        LynxShell.installAppHomeHandler(handler)
    }

    /** 打开本地或 HTTPS Bundle；params 同时作为 initData 与 queryItems。 */
    fun open(
        context: Context,
        bundle: String,
        params: Map<String, Any?> = emptyMap(),
        options: Map<String, Any?> = emptyMap(),
    ): LynxNavigationResult =
        LynxShell.open(context, bundle, optionsJson(params, options))

    /**
     * 打开 Activity-first OTA 页面。
     *
     * 业务只传 `lynxAppId + bundleName + params`；current 路径由 OTA SDK 解析，绝不要求
     * 业务注册 route 映射，也不把绝对路径写入 Intent。
     */
    fun open(
        context: Context,
        lynxAppId: String,
        bundleName: String,
        params: Map<String, Any?> = emptyMap(),
        options: Map<String, Any?> = emptyMap(),
    ): LynxNavigationResult {
        require(lynxAppId.isNotBlank()) { "lynxAppId 不能为空" }
        require(bundleName.isNotBlank()) { "bundleName 不能为空" }
        val otaOptions = options.toMutableMap().apply {
            put("lynxAppId", lynxAppId)
            put("bundleName", bundleName)
        }
        // bundleUrl 只作为 Lynx render key；真正的文件由 ActivityBundleRuntime 交付。
        return LynxShell.open(
            context,
            normalizeOtaBundle(bundleName),
            optionsJson(params, otaOptions),
        )
    }

    /** `hybrid://lynxview_page?...`、`lynxshell://...` 与 Bundle 地址共用同一入口。 */
    fun openScheme(
        context: Context,
        scheme: String,
        params: Map<String, Any?> = emptyMap(),
        options: Map<String, Any?> = emptyMap(),
    ): LynxNavigationResult =
        open(context, scheme, params, options)

    /** 原位替换当前 Activity 的 Bundle，entry/session 身份保持不变。 */
    fun replace(
        context: Context,
        bundle: String,
        params: Map<String, Any?> = emptyMap(),
        options: Map<String, Any?> = emptyMap(),
    ): LynxNavigationResult {
        val optionsJson = optionsJson(params, options)
        val request = LynxRouteParser.fromBridge(bundle, optionsJson)
        return LynxNavigator.redirect(
            context,
            request,
            LynxNavigationOptions.fromJson(optionsJson),
        )
    }

    /** 关闭当前 Lynx Activity；根页面会回到宿主锚点。 */
    fun pop(context: Context): LynxNavigationResult = LynxNavigator.close(context)

    /** 回到当前 session 中最近的 pageKey/Bundle。 */
    fun popTo(context: Context, pageKey: String): LynxNavigationResult =
        LynxNavigator.popTo(context, pageKey)

    /** 关闭当前 Lynx session，不会清空业务 App 的整个 task。 */
    fun closeAll(context: Context): LynxNavigationResult = LynxNavigator.closeAll(context)

    /** 清空当前 session 后打开一个新 Bundle。 */
    fun reLaunch(
        context: Context,
        bundle: String,
        params: Map<String, Any?> = emptyMap(),
        options: Map<String, Any?> = emptyMap(),
    ): LynxNavigationResult {
        val closed = closeAll(context)
        return if (closed.isSuccess) open(context, bundle, params, options) else closed
    }

    /** 安装 JS -> Native 的进程级消息处理器。 */
    fun setMessageHandler(handler: LynxRouterMessageHandler?) {
        ShellMessageHub.setMessageHandler(handler)
    }

    /** 返回仍持有 LynxView 的页面实例；列表中的 pageId 可用于 sendToPage。 */
    fun activePages() = ShellMessageHub.pages()

    /** 向全部活体 Lynx 页面发送 GlobalEvent。 */
    fun broadcast(eventName: String, payload: Map<String, Any?> = emptyMap()): Int =
        ShellMessageHub.broadcast(eventName, payload)

    /** 按页面实例 pageId 定向发送 GlobalEvent。 */
    fun sendToPage(pageId: String, eventName: String, payload: Map<String, Any?> = emptyMap()): Boolean =
        ShellMessageHub.sendToPage(pageId, eventName, payload)

    /** 组合页面 params 与原生 options；不写入任何 route 映射表。 */
    private fun optionsJson(
        params: Map<String, Any?>,
        options: Map<String, Any?>,
    ): String {
        val merged = options.toMutableMap()
        merged["initData"] = params
        val globalProps = (options["globalProps"] as? Map<*, *>)
            ?.entries
            ?.filter { it.key is String }
            ?.associate { (key, value) -> key as String to value }
            ?.toMutableMap()
            ?: mutableMapOf()
        globalProps["queryItems"] = params
        merged["globalProps"] = globalProps
        return JSONObject(merged).toString()
    }

    private fun normalizeOtaBundle(bundleName: String): String {
        val normalized = bundleName.trim().removePrefix("./").removePrefix("/")
        return if (normalized.startsWith("assets://")) {
            normalized
        } else if (normalized.startsWith("bundles/", ignoreCase = true)) {
            "assets://$normalized"
        } else {
            "assets://bundles/$normalized"
        }
    }
}

internal object LynxDebugFaults {
    @Volatile
    var failNextFirstScreen: Boolean = false

    fun consumeFirstScreenFailure(): Boolean {
        if (!failNextFirstScreen) return false
        failNextFirstScreen = false
        return true
    }
}
