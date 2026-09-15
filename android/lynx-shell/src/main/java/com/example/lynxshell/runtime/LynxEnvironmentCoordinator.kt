package com.example.lynxshell.runtime

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.view.View
import com.lynx.jsbridge.Arguments
import com.lynx.react.bridge.JavaOnlyArray
import com.lynx.tasm.LynxView
import com.lynx.tasm.TemplateData
import java.util.Collections
import java.util.IdentityHashMap

/** Lynx 4.1 环境变化的唯一 Android UI 主线程同步入口。 */
object LynxEnvironmentCoordinator {
    const val LOCALE_CHANGED_EVENT = "lynxShellLocaleChanged"
    const val LAYOUT_CHANGED_EVENT = "lynxShellLayoutChanged"

    private val mainHandler = Handler(Looper.getMainLooper())
    private val bindings = Collections.synchronizedMap(IdentityHashMap<LynxView, Binding>())
    private var layoutRevision = 0L

    private class Binding(
        val activity: Activity,
        val view: LynxView,
    ) {
        var pending = false
        var lastLayoutSignature: List<Any?>? = null
        var lastLocaleRevision: Long? = null
        lateinit var layoutListener: View.OnLayoutChangeListener
        lateinit var scheduledSync: Runnable
    }

    fun bind(activity: Activity, view: LynxView) {
        requireMainThread()
        unbind(view)
        val binding = Binding(activity, view)
        binding.layoutListener = View.OnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
            schedule(binding)
        }
        binding.scheduledSync = Runnable {
            binding.pending = false
            if (bindings[view] === binding) syncNow(binding)
        }
        bindings[view] = binding
        view.addOnLayoutChangeListener(binding.layoutListener)
        schedule(binding)
    }

    fun unbind(view: LynxView?) {
        requireMainThread()
        if (view == null) return
        val binding = bindings.remove(view) ?: return
        view.removeOnLayoutChangeListener(binding.layoutListener)
        mainHandler.removeCallbacks(binding.scheduledSync)
    }

    fun synchronize(activity: Activity) {
        requireMainThread()
        bindings.values.filter { it.activity === activity }.forEach(::schedule)
    }

    /** 更新所有存活（包括隐藏 Tab）的 locale；返回已经排入更新的 View 数量。 */
    fun updateLocale(state: LynxLocaleState): Int {
        requireMainThread()
        val live = bindings.values.toList()
        live.forEach { syncNow(it, forcedLocale = state) }
        return live.size
    }

    private fun schedule(binding: Binding) {
        requireMainThread()
        if (binding.pending || bindings[binding.view] !== binding) return
        binding.pending = true
        mainHandler.post(binding.scheduledSync)
    }

    private fun syncNow(binding: Binding, forcedLocale: LynxLocaleState? = null) {
        if (binding.activity.isFinishing || binding.activity.isDestroyed) return
        val snapshot = LynxLayoutSnapshot.capture(binding.activity, binding.view)
        val locale = forcedLocale ?: LynxLocaleStore.current(binding.activity)
        val layoutChanged = snapshot.signature() != binding.lastLayoutSignature
        val localeChanged = binding.lastLocaleRevision != null &&
            binding.lastLocaleRevision != locale.revision
        if (forcedLocale == null && !layoutChanged && !localeChanged) return
        if (layoutChanged) {
            layoutRevision += 1L
            binding.lastLayoutSignature = snapshot.signature()
        }
        val props = ShellGlobalPropsFactory.createEnvironment(
            activity = binding.activity,
            view = binding.view,
            snapshot = snapshot,
            layoutRevision = layoutRevision,
            locale = locale,
        )
        binding.view.updateScreenMetrics(snapshot.screenWidthPx, snapshot.screenHeightPx)
        val viewportWidth = snapshot.viewportWidthPx
        val viewportHeight = snapshot.viewportHeightPx
        if (viewportWidth != null && viewportHeight != null) {
            binding.view.updateViewport(
                View.MeasureSpec.makeMeasureSpec(viewportWidth, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(viewportHeight, View.MeasureSpec.EXACTLY),
                true,
            )
        }
        binding.view.updateGlobalProps(TemplateData.fromMap(props))
        binding.view.updateColorScheme(ShellGlobalPropsFactory.resolveColorScheme(binding.activity))
        binding.lastLocaleRevision = locale.revision
        if (forcedLocale != null || localeChanged) {
            sendEvent(binding.view, LOCALE_CHANGED_EVENT, locale.toMap())
        }
        if (layoutChanged) {
            sendEvent(
                binding.view,
                LAYOUT_CHANGED_EVENT,
                props.filterKeys {
                    it == "screenWidth" || it == "screenHeight" ||
                        it == "viewportWidth" || it == "viewportHeight" ||
                        it == "layoutRevision" || it == "orientation" || it == "windowMode"
                },
            )
        }
    }

    private fun sendEvent(view: LynxView, eventName: String, payload: Map<String, Any>) {
        view.sendGlobalEvent(
            eventName,
            JavaOnlyArray.of(Arguments.makeNativeMap(HashMap(payload))),
        )
    }

    private fun requireMainThread() {
        check(Looper.myLooper() == Looper.getMainLooper()) {
            "LynxEnvironmentCoordinator 必须在 Android 主线程调用"
        }
    }
}
