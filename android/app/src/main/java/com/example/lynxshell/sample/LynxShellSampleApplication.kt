package com.example.lynxshell.sample

import android.app.Application
import android.app.Activity
import android.content.Intent
import android.os.Bundle
import com.example.lynxshell.LynxRouter
import com.example.lynxshell.LynxShell
import com.example.lynxshell.ota.LynxOtaConfig
import com.example.lynxshell.routing.AppHomeHandler
import java.net.URI

/**
 * App 级 Lynx 启动入口。
 *
 * LynxEnv 必须早于任何 LynxView 创建；初始化顺序集中在 RuntimeInitializer，
 * 避免业务 Activity 重复注册 Service 或 Native Module。
 */
class LynxShellSampleApplication : Application() {
    private var startedActivityCount = 0
    private var hasCompletedInitialForeground = false

    override fun onCreate() {
        super.onCreate()
        // 三端统一入口：Android 具体承载仍是 Activity-first；OTA 适配器只在宿主 App 注入。
        // Router 不依赖 OTA SDK，也不需要注册 Bundle route 映射。
        LynxRouter.install(
            this,
            LynxOtaConfig(
                apiBaseUri = URI.create("https://lynx-ota-server.test.huangbaoche.com"),
                hostApp = "capp",
                defaultLynxAppId = "10000001",
                environment = "TEST",
                platform = "android",
                clientToken = BuildConfig.LYNX_OTA_CLIENT_TOKEN,
            ),
        )

        registerActivityLifecycleCallbacks(object : ActivityLifecycleCallbacks {
            override fun onActivityStarted(activity: Activity) {
                if (startedActivityCount == 0 && hasCompletedInitialForeground) {
                    // 从后台回到前台：再次拉取全量 latest-bundle-list，并后台更新有变化的包。
                    LynxRouter.onApplicationForeground()
                }
                startedActivityCount += 1
                hasCompletedInitialForeground = true
            }

            override fun onActivityStopped(activity: Activity) {
                startedActivityCount = (startedActivityCount - 1).coerceAtLeast(0)
            }

            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
            override fun onActivityResumed(activity: Activity) = Unit
            override fun onActivityPaused(activity: Activity) = Unit
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
            override fun onActivityDestroyed(activity: Activity) = Unit
        })

        // 壳工程没有业务 TabBar，因此示例 Home Handler 返回原生调试首页。
        // 业务 App 接入时在自己的 Application 中覆盖为“选中 TabBar + 返回根页面”。
        LynxShell.installAppHomeHandler(
            AppHomeHandler { activity, _ ->
                activity.startActivity(
                    Intent(activity, MainActivity::class.java)
                        .addFlags(
                            Intent.FLAG_ACTIVITY_CLEAR_TOP or
                                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                                Intent.FLAG_ACTIVITY_NO_ANIMATION,
                        ),
                )
                @Suppress("DEPRECATION")
                activity.overridePendingTransition(0, 0)
                true
            },
        )
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        LynxShell.onTrimMemory(level)
    }
}
