package com.example.lynxshell.sample

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import com.example.lynxcapacitormodule.LynxCapacitorModule
import com.example.lynxcapacitormodule.LynxCapacitorRuntime
import com.example.lynxcapacitormodule.LynxCapacitorHost
import com.example.lynxcapacitormodule.LynxCapacitorHostProvider
import com.example.lynxshell.LynxShell
import com.example.lynxshell.LynxRouter
import com.example.lynxshell.runtime.LynxNativeMediaHost
import com.example.lynxshell.runtime.LynxNativeModuleHost
import com.example.lynxshell.runtime.LynxSystemUIHandle
import com.example.lynxshell.runtime.LynxSystemUIResult
import com.lynx.tasm.LynxEnv
import com.lynx.tasm.LynxView
import java.lang.ref.WeakReference
import java.util.WeakHashMap
import org.json.JSONObject

/** Demo composition root 显式连接独立 Shell 与能力模块，二者不互相依赖。 */
object LynxCapacitorDemoHost : LynxNativeModuleHost, LynxNativeMediaHost, LynxCapacitorHostProvider {
    private val activeViews = WeakHashMap<Activity, WeakReference<LynxView>>()
    private val adapters = WeakHashMap<Context, SystemUIAdapter>()

    override val supportedMethods = setOf(
        "StatusBar.setStyle", "StatusBar.hide", "StatusBar.show",
        "SystemBars.setStyle",
        "SafeArea.setSystemBarsStyle", "SafeArea.hideSystemBars", "SafeArea.showSystemBars",
        "ScreenOrientation.lock", "ScreenOrientation.unlock",
        "TextZoom.get", "TextZoom.set",
    )

    fun install(application: Application) {
        LynxCapacitorRuntime.install(application)
        LynxCapacitorRuntime.setHostProvider(this)
        LynxEnv.inst().registerModule(LynxCapacitorModule.MODULE_NAME, LynxCapacitorModule::class.java)
        LynxShell.installNativeModuleHost(this)
        LynxShell.installNativeMediaHost(this)
    }

    override fun call(callerContext: Context, methodName: String, optionsJSON: String, complete: (JSONObject) -> Unit) {
        LynxCapacitorRuntime.handleLegacyMedia(callerContext, methodName, optionsJSON, complete)
    }

    override fun onViewDestroy(callerContext: Context) {
        LynxCapacitorRuntime.destroyForContext(callerContext)
        release(callerContext)
    }

    override fun onViewActive(activity: Activity, view: LynxView) {
        val previous = activeViews[activity]?.get()
        if (previous !== view) {
            if (previous != null) {
                adapters.values.firstOrNull { it.handle.sourceView === previous && it.handle.owningActivity === activity }
                    ?.handle?.deactivate()
            }
            activeViews[activity] = WeakReference(view)
            adapters.values.firstOrNull { it.handle.sourceView === view }?.handle?.activate()
        }
        LynxCapacitorRuntime.activate(view.lynxContext)
    }

    override fun resolve(callerContext: Context): LynxCapacitorHost? {
        val cached = adapters[callerContext]
        if (cached != null) return cached.takeIf { it.handle.isAvailable }
        val handle = LynxRouter.systemUIHandle(callerContext) ?: return null
        if (!isActive(handle)) return null
        return SystemUIAdapter(handle).also { adapters[callerContext] = it }
    }

    override fun release(callerContext: Context) {
        val adapter = adapters.remove(callerContext) ?: return
        val activity = adapter.handle.owningActivity
        val sourceView = adapter.handle.sourceView
        val ownsWindow = activity != null && sourceView != null && activeViews[activity]?.get() === sourceView
        adapter.handle.release(restoreWindowState = ownsWindow)
        if (ownsWindow) activeViews.remove(activity)
    }

    private fun isActive(handle: LynxSystemUIHandle): Boolean =
        handle.isAvailable && handle.owningActivity?.let { activeViews[it]?.get() === handle.sourceView } == true

    private class SystemUIAdapter(val handle: LynxSystemUIHandle) : LynxCapacitorHost {
        override fun call(pluginId: String, methodName: String, options: JSONObject, complete: (JSONObject) -> Unit) {
            if (!isActive(handle)) {
                complete(error("HOST_INACTIVE", "调用页面当前不是该 Activity 的系统 UI owner"))
                return
            }
            val reply: (LynxSystemUIResult) -> Unit = { result -> complete(envelope(result)) }
            when ("$pluginId.$methodName") {
                "StatusBar.setStyle" -> reply(handle.setStatusBarStyle(options.optString("style", "DEFAULT")))
                "StatusBar.hide" -> handle.setBarsVisible("StatusBar", false, reply)
                "StatusBar.show" -> handle.setBarsVisible("StatusBar", true, reply)
                "SystemBars.setStyle", "SafeArea.setSystemBarsStyle" -> reply(handle.setSystemBarsStyle(options.optString("style", "DEFAULT")))
                "SafeArea.hideSystemBars" -> handle.setBarsVisible(options.optString("type", "StatusBar"), false, reply)
                "SafeArea.showSystemBars" -> handle.setBarsVisible(options.optString("type", "StatusBar"), true, reply)
                "ScreenOrientation.lock" -> handle.lockOrientation(options.optString("orientation", "portrait"), reply)
                "ScreenOrientation.unlock" -> handle.unlockOrientation(reply)
                "TextZoom.get" -> reply(handle.getTextZoom())
                "TextZoom.set" -> reply(handle.setTextZoom(options.optDouble("value", Double.NaN)))
                else -> complete(error("UNSUPPORTED", "当前 Host 未提供 $pluginId.$methodName"))
            }
        }
    }

    private fun envelope(result: LynxSystemUIResult): JSONObject =
        result.errorCode?.let { error(it, result.message) } ?: JSONObject(result.data)

    private fun error(code: String, message: String): JSONObject =
        JSONObject().put("error", JSONObject().put("code", code).put("message", message))

    override fun onActivityResult(activity: Activity, requestCode: Int, resultCode: Int, data: Intent?) {
        LynxCapacitorRuntime.onActivityResult(requestCode, resultCode, data)
    }

    override fun onRequestPermissionsResult(activity: Activity, requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        LynxCapacitorRuntime.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onNewIntent(activity: Activity, intent: Intent) {
        // 只转发通知动作，不覆盖 Shell Intent 中的页面身份和恢复参数。
        LynxCapacitorRuntime.onNotificationAction(activity, intent)
    }
}
