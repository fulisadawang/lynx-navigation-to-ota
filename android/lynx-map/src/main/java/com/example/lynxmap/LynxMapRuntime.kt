package com.example.lynxmap

import android.content.Context
import android.os.RemoteException
import com.amap.api.location.AMapLocationClient
import com.amap.api.maps.MapsInitializer
import com.lynx.tasm.LynxViewBuilder

/** Android 地图 Module 的宿主接线边界；不把 Key 或 AMap 类型暴露给 Lynx 页面。 */
object LynxMapRuntime {
    @Volatile
    private var configured = false

    @JvmStatic
    fun configure(context: Context, apiKey: String, privacyAgreed: Boolean) {
        if (apiKey.isBlank()) return
        MapsInitializer.setApiKey(apiKey)
        MapsInitializer.updatePrivacyShow(context, true, privacyAgreed)
        MapsInitializer.updatePrivacyAgree(context, privacyAgreed)
        AMapLocationClient.setApiKey(apiKey)
        AMapLocationClient.updatePrivacyShow(context, true, privacyAgreed)
        AMapLocationClient.updatePrivacyAgree(context, privacyAgreed)
        runCatching { MapsInitializer.initialize(context.applicationContext) }
        configured = privacyAgreed
    }

    @JvmStatic
    fun isConfigured(): Boolean = configured

    /** 每个 LynxViewBuilder 都必须安装地图 Behavior，Activity 和 Tab 共用此入口。 */
    @JvmStatic
    fun install(builder: LynxViewBuilder) {
        builder.addBehavior(LynxMapBehavior())
        builder.registerModule("LynxMapLocationModule", LynxMapLocationModule::class.java)
        builder.registerModule("LynxMapSearchModule", LynxMapSearchModule::class.java)
    }

}
