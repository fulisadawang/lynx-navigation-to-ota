package com.example.lynxshell.container

import android.app.Activity
import android.app.Application
import android.content.ComponentCallbacks2
import android.content.res.Configuration
import android.os.Handler
import android.os.Build
import android.os.Looper
import android.os.SystemClock
import com.example.lynxshell.model.LynxPageRequest
import com.example.lynxshell.ota.PreparedActivityBundle
import com.example.lynxshell.resource.TemplateGroupResources
import com.example.lynxshell.resource.ShellTemplateProvider
import com.example.lynxshell.runtime.LynxLayoutSnapshot
import com.example.lynxshell.runtime.LynxLocaleStore
import com.example.lynxshell.runtime.ShellGlobalPropsFactory
import com.lynx.tasm.LynxBooleanOption
import com.lynx.tasm.LynxError
import com.lynx.tasm.LynxView
import com.lynx.tasm.LynxViewBuilder
import com.lynx.tasm.LynxViewClient
import com.lynx.tasm.LynxViewClientV2
import com.lynx.tasm.performance.performanceobserver.PerformanceEntry
import com.lynx.tasm.performance.performanceobserver.ReloadBundleEntry
import com.lynx.tasm.TemplateData
import com.lynx.tasm.behavior.ui.LynxBaseUI
import com.lynx.tasm.group.ILynxViewGroup
import com.lynx.tasm.group.LynxViewGroupBuilder
import com.ota.android.sdk.OtaSidecarViewResources
import java.util.WeakHashMap
import java.lang.ref.WeakReference
import android.view.ViewTreeObserver

/** warm 的真实绘制收据单独命名，不伪造 SDK 的 cold onFirstScreen。 */
enum class LynxFirstFrameSource { CACHED_FRAME_COMMITTED, CACHED_DRAW_CYCLE }

/** 固定 ReactLynx 版本下每个 Engine 最多借给一个新页面，归还后销毁整个 Group。 */
internal object LynxTemplateGroupCache {
    private const val IDLE_TTL_MS = 60_000L
    private val reusableTags = setOf("page", "view", "text", "raw-text", "inline-text", "image", "scroll-view", "component")
    private data class Key(val appId: String, val bundleName: String, val releaseId: String,
        val sha: String, val source: String, val selection: String?, val epoch: Long,
        val resources: String, val url: String, val width: Int, val height: Int,
        val presetWidth: Int?, val presetHeight: Int?, val density: Float,
        val theme: String, val locale: String, val fontScale: Float)
    internal class Slot(val group: ILynxViewGroup, val resources: TemplateGroupResources)
    private class Registration(val lease: EngineGroupPool.Lease<Slot>, view: LynxView,
        var ownedClient: LynxViewClient?, var onCachedFrame: ((LynxFirstFrameSource) -> Unit)?) {
        val view = WeakReference(view)
        @Volatile var firstScreen = false
        @Volatile var failed = false
        var runtimeReady = false
        var pageStarted = false
        var dataUpdated = false
        var loadSucceeded = false
        var pageUpdated = false
        var frameArmed = false
        var frameDelivered = false
        var drawListener: ViewTreeObserver.OnDrawListener? = null
        var preDrawListener: ViewTreeObserver.OnPreDrawListener? = null
        var drawObserver: ViewTreeObserver? = null
        var frameObserver: ViewTreeObserver? = null
        var frameCommit: Runnable? = null
        private var coldStarts = 0
        val clientV2 = object : LynxViewClientV2() {
            override fun onPageStarted(view: LynxView?, info: LynxPipelineInfo) = onMain {
                if (!lease.reused && (info.isFromReload || ++coldStarts > 1)) failed = true
            }
            override fun onPerformanceEvent(entry: PerformanceEntry) = onMain {
                if (!lease.reused && entry is ReloadBundleEntry) failed = true
            }
        }
        val client = object : LynxViewClient() {
            override fun onFirstScreen() { firstScreen = true }
            override fun onReceivedError(error: LynxError) { if (error.isFatal) failed = true }
            override fun onRuntimeReady() = onMain { runtimeReady = true; observeFrame(this@Registration) }
            override fun onPageStart(url: String?) = onMain {
                pageStarted = true; dataUpdated = false; pageUpdated = false; loadSucceeded = false
            }
            override fun onDataUpdated() = onMain {
                if (pageStarted) { dataUpdated = true; observeFrame(this@Registration) }
            }
            override fun onUpdateDataWithoutChange() = onMain {
                if (pageStarted) { dataUpdated = true; observeFrame(this@Registration) }
            }
            override fun onLoadSuccess() = onMain {
                if (pageStarted) { loadSucceeded = true; observeFrame(this@Registration) }
            }
            override fun onPageUpdate() = onMain {
                if (pageStarted) { pageUpdated = true; observeFrame(this@Registration) }
            }
        }
    }
    private val main = Handler(Looper.getMainLooper())
    private val pool = EngineGroupPool<Key, Slot>(2, 8L * 1024 * 1024, IDLE_TTL_MS,
        SystemClock::uptimeMillis) { slot -> try { slot.resources.unbind() } finally { slot.group.release() } }
    private val registrations = WeakHashMap<LynxView, Registration>()
    private var registeredApplication: Application? = null
    private val expiry = Runnable { pool.evictExpired() }

    fun initialize(application: Application) {
        if (registeredApplication === application) return
        check(registeredApplication == null) { "引擎缓存只能绑定一个 Application" }
        registeredApplication = application
        application.registerComponentCallbacks(object : ComponentCallbacks2 {
            override fun onConfigurationChanged(newConfig: Configuration) = clear()
            override fun onLowMemory() = clear()
            override fun onTrimMemory(level: Int) {
                if (level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW) clear()
            }
        })
    }

    fun configure(builder: LynxViewBuilder, activity: Activity, request: LynxPageRequest,
        provider: ShellTemplateProvider, prepared: PreparedActivityBundle?,
        sidecars: OtaSidecarViewResources?, layout: LynxLayoutSnapshot): EngineGroupPool.Lease<Slot>? {
        check(Looper.myLooper() == Looper.getMainLooper())
        val value = prepared ?: return null
        // 候选版本必须保留原有 SDK 首屏与业务健康确认，不能从未确认页捐赠 Engine。
        if (value.source == "candidate_trial") return null
        val sha = value.sha256?.lowercase() ?: return null
        if (!Regex("sha256:[0-9a-f]{64}").matches(sha) || value.releaseId.isNullOrBlank() ||
            value.userIdentityEpoch == null || (sidecars != null && sidecars.snapshotIdentity == null)) return null
        val bytes = value.file?.length() ?: value.bytes?.size?.toLong() ?: return null
        val key = Key(value.lynxAppId, value.bundleName, value.releaseId, sha, value.source,
            value.selectionKind, value.userIdentityEpoch, sidecars?.snapshotIdentity ?: "none",
            request.bundleUrl, layout.screenWidthPx, layout.screenHeightPx, request.widthPx, request.heightPx,
            request.density ?: activity.resources.displayMetrics.density,
            ShellGlobalPropsFactory.resolveThemeName(activity), LynxLocaleStore.current(activity).effectiveLocale,
            activity.resources.configuration.fontScale)
        // 同一 App 的旧用户缓存禁止再借；仍显示的旧页等待自己的 destroy。
        pool.invalidate { it.appId == key.appId && it.epoch != key.epoch }
        val lease = pool.acquire(key, bytes) {
            val resources = TemplateGroupResources(request.bundleUrl, sha)
            resources.bind(provider, sidecars)
            val groupBuilder = LynxViewGroupBuilder().setContext(activity.applicationContext)
                .setUrl(request.bundleUrl).setEnableCacheEngine(true).setEnableSharedModule(false)
            groupBuilder.setTemplateResourceFetcher(resources.template)
            val group = groupBuilder.build()
            resources.attachGroup(group)
            Slot(group, resources)
        }
        if (lease.reused) {
            lease.value.resources.bind(provider, sidecars)
            provider.releasePreparedBytes()
        }
        builder.setLynxViewGroup(lease.value.group)
        builder.setEnableGenericResourceFetcher(LynxBooleanOption.TRUE)
        builder.setTemplateResourceFetcher(lease.value.resources.template)
        builder.setGenericResourceFetcher(lease.value.resources.generic)
        builder.setMediaResourceFetcher(lease.value.resources.media)
        return lease
    }

    fun attach(view: LynxView, lease: EngineGroupPool.Lease<Slot>, ownedClient: LynxViewClient?,
        onCachedFrame: ((LynxFirstFrameSource) -> Unit)?) {
        val registration = Registration(lease, view, ownedClient, onCachedFrame)
        registrations[view] = registration
        view.addLynxViewClient(registration.client)
        view.addLynxViewClientV2(registration.clientV2)
    }
    fun prepareFreshPage(view: LynxView, data: Map<String, Any>, globalProps: Map<String, Any>) {
        if (!isReused(view)) return
        // 在新 BTS App 启动之前执行；各次调用创建独立 TemplateData，避免已消费数据复用。
        view.resetData(TemplateData.fromMap(data))
        view.reloadTemplate(TemplateData.fromMap(data), TemplateData.fromMap(globalProps))
        // 缓存 UI 的 Android 子 View 在物理 attach/measure 之前必须重建。
        view.lynxUIRenderer().lynxUIOwner().rootUI.rebuildViewTree()
    }
    fun abort(lease: EngineGroupPool.Lease<Slot>) {
        try { lease.value.resources.unbind() } finally { lease.close(false) }
    }
    fun destroy(view: LynxView) {
        val registration = registrations.remove(view)
        if (registration == null) { view.destroy(); return }
        var reusable = false
        try {
            val context = view.lynxContext
            val owner = view.lynxUIRenderer().lynxUIOwner()
            val body = owner.rootUI
            // SDK holder 可能保留条件移除的节点，公开聚合覆盖这些 orphan，不私改索引。
            val tags = owner.memoryUsage?.keys
            val containsNativeElement = containsHostOwnedUI(body) || tags == null || tags.any { it !in reusableTags }
            view.removeLynxViewClient(registration.client)
            view.removeLynxViewClientV2(registration.clientV2)
            registration.ownedClient?.let(view::removeLynxViewClient)
            stopObserving(registration)
            val drained = registration.lease.value.resources.unbind()
            view.destroy()
            body?.tryRunDetachAndAttachTask()
            val detached = body != null && body.view == null && body.bodyView == null
            // detach 已保存 ViewInfo；旧 Android 子 View 不再连接到 Activity 的 LynxView。
            view.removeAllViews()
            // SDK 的 drawing helper 仍强持旧 body View，公开初始化以 null body 重新建 helper。
            if (detached) body.initialize()
            context.setBaseContext(context.applicationContext)
            context.setUIBodyView(null)
            context.setLynxViewClient(null)
            context.setLynxViewClientV2(null)
            // 该 fetcher 强持旧 Renderer；新 View 的 SDK 初始化会为新 context 重新安装。
            context.setListNodeInfoFetcher(null)
            // 已借过的 Engine 不再入 idle，阻断第三次 fresh BTS 与旧 MTS 的状态累积。
            reusable = detached && !registration.lease.reused && drained && registration.firstScreen &&
                !registration.failed && !containsNativeElement
        } finally {
            registration.ownedClient = null
            registration.onCachedFrame = null
            try { view.removeLynxViewClient(registration.client) } finally {
                view.removeLynxViewClientV2(registration.clientV2)
                try { registration.lease.value.resources.unbind() } finally {
                    try { view.destroy() } finally { registration.lease.close(reusable) }
                }
            }
            main.postDelayed(expiry, IDLE_TTL_MS)
        }
    }
    fun invalidateApp(appId: String) = onMain { pool.invalidate { it.appId == appId } }
    fun isReused(view: LynxView?): Boolean = view != null && registrations[view]?.lease?.reused == true
    fun reject(view: LynxView?) { view?.let { registrations[it]?.failed = true } }
    fun clear() = onMain { pool.clear() }
    private fun observeFrame(registration: Registration) {
        val view = registration.view.get() ?: return
        if (!registration.lease.reused || !registration.runtimeReady || !registration.pageUpdated ||
            !registration.pageStarted || !registration.dataUpdated || !registration.loadSucceeded ||
            registration.failed || registration.frameDelivered || registration.drawListener != null || registration.preDrawListener != null ||
            registrations[view] !== registration) return
        fun arm(source: LynxFirstFrameSource) {
            val current = registration.view.get() ?: return
            if (!registration.frameArmed && !registration.failed && current.isShown && current.width > 0 && current.height > 0) {
                registration.frameArmed = true
                val complete = Runnable {
                    main.post {
                        stopObserving(registration)
                        val attached = registration.view.get()
                        if (attached != null && registrations[attached] === registration && attached.isAttachedToWindow && !registration.failed &&
                            !registration.frameDelivered) {
                            registration.frameDelivered = true
                            registration.onCachedFrame?.invoke(source)
                        }
                    }
                }
                if (source == LynxFirstFrameSource.CACHED_FRAME_COMMITTED) {
                    registration.frameObserver = current.viewTreeObserver
                    registration.frameCommit = complete
                    current.viewTreeObserver.registerFrameCommitCallback(complete)
                } else main.post(complete)
            }
        }
        registration.drawObserver = view.viewTreeObserver
        if (Build.VERSION.SDK_INT >= 29 && view.isHardwareAccelerated) {
            // performDraw 在 dispatchOnDraw 前抓取 commit callbacks，必须提前注册本帧收据。
            val listener = ViewTreeObserver.OnPreDrawListener { arm(LynxFirstFrameSource.CACHED_FRAME_COMMITTED); true }
            registration.preDrawListener = listener
            view.viewTreeObserver.addOnPreDrawListener(listener)
        } else {
            val listener = ViewTreeObserver.OnDrawListener { arm(LynxFirstFrameSource.CACHED_DRAW_CYCLE) }
            registration.drawListener = listener
            view.viewTreeObserver.addOnDrawListener(listener)
        }
        view.invalidate()
    }
    private fun stopObserving(registration: Registration) {
        registration.drawListener?.let { listener -> registration.drawObserver?.takeIf { it.isAlive }?.removeOnDrawListener(listener) }
        registration.preDrawListener?.let { listener -> registration.drawObserver?.takeIf { it.isAlive }?.removeOnPreDrawListener(listener) }
        if (Build.VERSION.SDK_INT >= 29) registration.frameCommit?.let { callback ->
            registration.frameObserver?.takeIf { it.isAlive }?.unregisterFrameCommitCallback(callback)
        }
        registration.drawListener = null
        registration.preDrawListener = null
        registration.drawObserver = null
        registration.frameCommit = null
        registration.frameObserver = null
    }
    private fun containsHostOwnedUI(ui: LynxBaseUI?): Boolean {
        if (ui == null) return false
        // 业务与 XElement 的独立资源尚无脱绑证据，不允许进入 idle Engine 缓存。
        return !ui.javaClass.name.startsWith("com.lynx.tasm.behavior.ui.") ||
            ui.children.any(::containsHostOwnedUI)
    }
    private fun onMain(action: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) action() else main.post(action)
    }
}
