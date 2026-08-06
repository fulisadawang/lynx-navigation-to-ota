package com.example.lynxshell

import android.app.Activity
import android.app.Application
import android.content.Context
import com.example.lynxshell.model.LynxPageRequest
import com.example.lynxshell.routing.AppHomeHandler
import com.example.lynxshell.routing.LynxNavigationOptions
import com.example.lynxshell.routing.LynxNavigationResult
import com.example.lynxshell.routing.LynxNavigator
import com.example.lynxshell.routing.LynxRouteParser
import com.example.lynxshell.routing.SessionExitHandler
import com.example.lynxshell.runtime.LynxRuntimeInitializer
import com.example.lynxshell.ota.ActivityBundleRuntime
import com.example.lynxshell.transition.LynxSnapshotStore
import com.example.lynxshell.transition.PreparedRouteStore

/**
 * Android Lynx 壳对业务 App 暴露的唯一高层入口。
 *
 * Interface 只负责 Runtime 初始化、宿主 Handler 安装和页面打开；Activity、Provider、
 * NativeModules、路由栈与转场全部留在本 Library 的 Implementation 内。业务工程无需
 * 复制壳源码，也不需要 Sparkling autolink。
 */
object LynxShell {
    /**
     * 当前宿主注入的 Activity-first OTA runtime。
     *
     * 默认由 Router 内置的 LynxOtaRuntime 提供；保留接口引用是为了允许已有宿主替换
     * 网络层或存储实现，Activity 创建页面时再读取最新 runtime。
     */
    @Volatile
    private var installedActivityBundleRuntime: ActivityBundleRuntime? = null

    /** 示例默认 Bundle；真实业务通常传自己的 assets 或 HTTPS 地址。 */
    val defaultBundleUrl: String get() = BuildConfig.DEFAULT_BUNDLE_URL

    /** 供宿主决定是否展示“允许 HTTP”调试开关，Release 恒为 false。 */
    val isDebugBuild: Boolean get() = BuildConfig.DEBUG

    /** 必须在 Application.onCreate 中、创建首个 LynxView 前调用。 */
    fun initialize(application: Application) {
        LynxRuntimeInitializer.initialize(application)
    }

    /** 安装宿主 OTA 适配器；传 null 表示关闭显式 appId + bundleName 页面。 */
    fun installActivityBundleRuntime(runtime: ActivityBundleRuntime?) {
        installedActivityBundleRuntime = runtime
    }

    /** 仅由 Shell Activity 读取，不把 OTA SDK 的内部类型暴露给页面。 */
    internal fun activityBundleRuntime(): ActivityBundleRuntime? = installedActivityBundleRuntime

    /** 注入“回到业务主 Tab/主页”的实现；后续注入会替换旧 Handler。 */
    fun installAppHomeHandler(handler: AppHomeHandler) {
        LynxNavigator.installAppHomeHandler(handler)
    }

    /** 可选：混合原生页面与 Lynx 页面时，注入返回 session 锚点的业务 Router。 */
    fun installSessionExitHandler(handler: SessionExitHandler?) {
        LynxNavigator.installSessionExitHandler(handler)
    }

    /** 原生宿主已经构造好 request 时使用。 */
    fun open(
        context: Context,
        request: LynxPageRequest,
        options: LynxNavigationOptions = LynxNavigationOptions(),
    ): LynxNavigationResult = LynxNavigator.open(context, request.validated(), options)

    /**
     * 最适合其他项目的字符串入口，与页面侧 NativeModules.open 使用相同协议。
     *
     * route 支持 assets、https、lynxshell、hybrid 和 Explorer local 地址；
     * optionsJson 同时承载页面参数、launchMode 与 transition。
     */
    fun open(
        context: Context,
        route: String,
        optionsJson: String = "{}",
    ): LynxNavigationResult {
        val request = LynxRouteParser.fromBridge(route, optionsJson)
        val options = LynxNavigationOptions.fromJson(optionsJson)
        return LynxNavigator.open(context, request, options)
    }

    /** 低内存时只清性能缓存，不破坏导航身份和页面结果。 */
    fun onTrimMemory(level: Int) {
        if (level >= Application.TRIM_MEMORY_RUNNING_LOW) {
            PreparedRouteStore.clear()
            LynxSnapshotStore.clear()
        }
    }

    /** 便于 Java 宿主使用 SAM；参数语义与 LynxNavigator 保持一致。 */
    fun interface HomeHandler {
        fun openHome(activity: Activity, optionsJson: String): Boolean
    }

    fun installAppHomeHandler(handler: HomeHandler) {
        installAppHomeHandler(AppHomeHandler(handler::openHome))
    }
}
