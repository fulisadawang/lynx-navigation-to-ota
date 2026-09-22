package com.example.lynxshell.runtime

import android.app.Application
import android.content.Context
import android.content.pm.ApplicationInfo
import com.lynx.devtoolwrapper.DevToolSettings
import com.lynx.service.devtool.LynxDevToolService
import com.lynx.tasm.LynxEnv
import com.lynx.tasm.service.LynxServiceCenter

/** Debug variant 的原生调试接线，不依赖页面 Bundle 的 __DEV__。 */
internal object LynxDevToolRuntime {
    fun beforeInitialize(application: Application) {
        val enabled = application.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
        DevToolSettings.inst().bootstrap().apply {
            setLynxDebugEnabled(enabled)
            setLogBoxEnabled(enabled)
            setLoadQJSBridge(enabled)
            setLoadV8Bridge(false)
        }
        if (enabled) {
            LynxServiceCenter.inst().registerService(LynxDevToolService.INSTANCE)
            LynxDevToolService.INSTANCE.enableAllSessions()
        }
    }

    fun afterInitialize(application: Application) {
        val enabled = application.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
        val env = LynxEnv.inst()
        env.enableLynxDebug(enabled)
        if (!enabled) return

        val settings = DevToolSettings.inst()
        val preferences = application.getSharedPreferences(LynxEnv.SP_NAME, Context.MODE_PRIVATE)
        // 只补未设置过的默认值，官方设置页的关闭选择在重启后仍然有效。
        if (!preferences.contains(DevToolSettings.SP_KEY_ENABLE_DEVTOOL)) env.enableDevtool(true)
        if (!preferences.contains(DevToolSettings.SP_KEY_ENABLE_LOGBOX)) env.enableLogBox(true)
        if (!preferences.contains(DevToolSettings.SP_KEY_ENABLE_DOM_TREE)) settings.setDOMTreeEnabled(true)
        if (!preferences.contains(DevToolSettings.SP_KEY_ENABLE_LONG_PRESS_MENU)) settings.setLongPressMenuEnabled(true)
    }
}
