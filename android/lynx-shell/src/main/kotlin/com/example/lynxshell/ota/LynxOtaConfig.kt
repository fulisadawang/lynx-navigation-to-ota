package com.example.lynxshell.ota

import android.content.Context
import android.os.Build
import android.provider.Settings
import com.ota.android.sdk.OtaModels
import java.io.File
import java.net.URI

/**
 * Router 内置 OTA 的宿主配置。
 *
 * 业务只需要配置服务端地址、宿主 App、环境和客户端令牌；Manifest、Bundle 下载、SHA
 * 校验、staging、current/previous 和回滚都由 Router 内部的 OTA 实现负责。这里保留
 * String 形式的 hostApp/environment/platform，避免业务方必须直接依赖 OTA SDK 的枚举。
 */
data class LynxOtaConfig(
    val apiBaseUri: URI,
    val hostApp: String = "capp",
    val defaultLynxAppId: String = OtaModels.DEFAULT_LYNX_APP_ID,
    val environment: String = "PROD",
    val platform: String = "android",
    val appVersion: String? = null,
    val buildNumber: String? = null,
    val userId: String? = null,
    val deviceId: String? = null,
    val deviceModel: String? = null,
    val osVersion: String? = null,
    val channel: String? = null,
    val region: String? = null,
    val nativeProtocolVersion: String? = null,
    val lynxSdkVersion: String? = "4.0.0",
    val clientToken: String? = null,
    val storageDirectory: File? = null,
    /** 本地 Bundle 有效时，页面打开触发当前 appId 后台检查的最小间隔。默认 30 分钟。 */
    val pageRefreshIntervalMillis: Long = DEFAULT_PAGE_REFRESH_INTERVAL_MILLIS,
) {
    companion object {
        /** 页面后台刷新默认 30 分钟；传 0 可用于测试时每次页面打开都检查。 */
        const val DEFAULT_PAGE_REFRESH_INTERVAL_MILLIS: Long = 30L * 60L * 1000L
    }

    init {
        require(apiBaseUri.scheme.equals("https", ignoreCase = true)) {
            "OTA apiBaseUri 必须使用 HTTPS"
        }
        require(apiBaseUri.host?.isNotBlank() == true) {
            "OTA apiBaseUri 必须包含 Host"
        }
        require(apiBaseUri.userInfo == null && apiBaseUri.query == null && apiBaseUri.fragment == null) {
            "OTA apiBaseUri 不能包含 userInfo、query 或 fragment"
        }
        require(defaultLynxAppId.isNotBlank()) { "defaultLynxAppId 不能为空" }
        require(pageRefreshIntervalMillis >= 0L) {
            "pageRefreshIntervalMillis 不能为负数"
        }
    }

    /** 把宿主友好的配置转换成 OTA 内部配置；不把绝对 Bundle 路径暴露给路由。 */
    internal fun toSdkConfiguration(context: Context): OtaModels.Configuration {
        val appContext = context.applicationContext
        val packageInfo = appContext.packageManager.getPackageInfo(appContext.packageName, 0)
        val resolvedVersion = appVersion ?: packageInfo.versionName
        val resolvedBuild = buildNumber ?: if (Build.VERSION.SDK_INT >= 28) {
            packageInfo.longVersionCode.toString()
        } else {
            @Suppress("DEPRECATION")
            packageInfo.versionCode.toString()
        }
        val resolvedDeviceId = deviceId ?: runCatching {
            Settings.Secure.getString(
                appContext.contentResolver,
                Settings.Secure.ANDROID_ID,
            )
        }.getOrNull()

        return OtaModels.Configuration(
            apiBaseUri,
            OtaModels.HostApp.fromWire(hostApp),
            defaultLynxAppId,
            OtaModels.Environment.fromWire(environment),
            OtaModels.Platform.fromWire(platform),
            resolvedVersion,
            resolvedBuild,
            userId,
            resolvedDeviceId,
            deviceModel ?: Build.MODEL,
            osVersion ?: Build.VERSION.RELEASE,
            channel,
            region,
            nativeProtocolVersion,
            lynxSdkVersion,
            clientToken,
            storageDirectory ?: File(appContext.filesDir, "lynx-ota-store"),
        )
    }
}
