package com.example.lynxshell.tab

import android.os.Bundle
import android.content.res.Configuration
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.TextView
import androidx.core.view.setPadding
import androidx.fragment.app.Fragment
import com.example.lynxshell.LynxShell
import com.example.lynxshell.LynxRouter
// LYNX_DEBUG_TOOL_BEGIN
import com.example.lynxshell.debug.LynxDebugBridge
// LYNX_DEBUG_TOOL_END
import com.example.lynxshell.bridge.LynxRouterPageInfo
import com.example.lynxshell.bridge.ShellMessageHub
import com.example.lynxshell.bridge.LynxOtaHealthCompletion
import com.example.lynxshell.bridge.LynxOtaHealthReply
import com.example.lynxshell.container.LynxContainerFactory
import com.example.lynxshell.model.KeyboardBehavior
import com.example.lynxshell.model.LynxPageRequest
import com.example.lynxshell.model.PageOrientation
import com.example.lynxshell.monitoring.BundleIdentities
import com.example.lynxshell.monitoring.ContainerKind
import com.example.lynxshell.monitoring.LoadKind
import com.example.lynxshell.monitoring.LynxMonitor
import com.example.lynxshell.monitoring.LynxViewMonitor
import com.example.lynxshell.monitoring.Visibility
import com.example.lynxshell.resource.ShellTemplateProvider
import com.example.lynxshell.runtime.LynxEnvironmentCoordinator
import com.example.lynxshell.runtime.LynxOtaHealthGate
import com.example.lynxshell.runtime.LynxLoadFailure
import com.example.lynxshell.ota.ActivityBundleRuntime
import com.example.lynxshell.util.JsonObjectCodec
import com.lynx.tasm.LynxError
import com.lynx.tasm.LynxView
import com.lynx.tasm.LynxViewClient
import java.lang.ref.WeakReference
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.CancellationException

/**
 * 无 TabBar 的 Android Lynx 内容承载能力。
 *
 * Fragment 不负责选中态、BottomNavigation 或业务 Tab 顺序；宿主可以用任意原生导航控件
 * 组合它。首次/显式刷新 cache-only 选择候选，普通切换复用 View，禁止在切 Tab 时联网。
 */
class LynxTabFragment : Fragment() {
    private var monitoringView: LynxViewMonitor? = null
    private lateinit var spec: LynxTabSpec
    private var lynxView: LynxView? = null
    private var templateProvider: ShellTemplateProvider? = null
    private var releaseLease: AutoCloseable? = null
    private var pageID: String = ""
    @Volatile
    private var loadGeneration: Long = 0L
    private var loadFuture: Future<*>? = null
    private var firstScreenReady = false
    private var loadFailureHandledGeneration: Long? = null
    private var otaHealthGate = LynxOtaHealthGate()
    private var healthFuture: Future<*>? = null
    private var pendingHealthCompletion: LynxOtaHealthCompletion? = null
    private var bundleRuntimeMetadata: Map<String, Any>? = null
    private var preparedRuntime: ActivityBundleRuntime? = null
    private var preparedUserEpoch: Long? = null
    private var otaRecoveryUsed = false
    private var debugIdentity = ""
    private var debugError = "idle"
    private var loadCount = 0
    private var renderCount = 0
    private val userContextListener: (Long) -> Unit = {
        if (::spec.isInitialized && spec.lynxAppId != null) refreshFromCurrent()
    }

    /** 原生验收 Host 可展示此只读状态；不联网、不改变加载策略。 */
    fun debugStateDescription(): String =
        "instance=${System.identityHashCode(this)};load=$loadCount;render=$renderCount;error=$debugError;$debugIdentity"
    private val loader: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "lynx-tab-loader").apply { isDaemon = true }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val arguments = requireArguments()
        spec = LynxTabSpec(
            tabId = requireNotNull(arguments.getString(ARG_TAB_ID)),
            bundleUrl = requireNotNull(arguments.getString(ARG_BUNDLE_URL)),
            title = arguments.getString(ARG_TITLE).orEmpty(),
            routeKey = arguments.getString(ARG_ROUTE_KEY).orEmpty(),
            initDataJson = arguments.getString(ARG_INIT_DATA).orEmpty().ifBlank { "{}" },
            globalPropsJson = arguments.getString(ARG_GLOBAL_PROPS).orEmpty().ifBlank { "{}" },
            lynxAppId = arguments.getString(ARG_APP_ID),
            bundleName = arguments.getString(ARG_BUNDLE_NAME),
            backgroundColor = arguments.getString(ARG_BACKGROUND).orEmpty().ifBlank { "#FFFFFF" },
        )
        pageID = "lynx-tab-${spec.tabId}-${System.identityHashCode(this)}"
    }

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?,
    ): View = FrameLayout(requireContext()).apply {
        setBackgroundColor(android.graphics.Color.parseColor(spec.backgroundColor))
        tag = pageID
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        LynxRouter.addOtaUserContextListener(userContextListener)
        loadContent(view as ViewGroup)
    }

    override fun onHiddenChanged(hidden: Boolean) {
        super.onHiddenChanged(hidden)
        monitoringView?.visibility(if (hidden || !isResumed) Visibility.HIDDEN else Visibility.VISIBLE)
        // LYNX_DEBUG_TOOL_BEGIN
        LynxDebugBridge.updateVisibility(lynxView, if (hidden || !isResumed) "hidden" else "visible")
        // LYNX_DEBUG_TOOL_END
        if (hidden) {
            lynxView?.onEnterBackground()
        } else {
            lynxView?.onEnterForeground()
            if (isResumed) lynxView?.let { LynxShell.nativeModuleHost()?.onViewActive(requireActivity(), it) }
            syncColorScheme()
        }
    }

    override fun onResume() {
        super.onResume()
        monitoringView?.visibility(if (isHidden) Visibility.HIDDEN else Visibility.VISIBLE)
        // LYNX_DEBUG_TOOL_BEGIN
        LynxDebugBridge.updateVisibility(lynxView, if (isHidden) "hidden" else "visible")
        // LYNX_DEBUG_TOOL_END
        if (!isHidden) {
            lynxView?.onEnterForeground()
            lynxView?.let { LynxShell.nativeModuleHost()?.onViewActive(requireActivity(), it) }
            syncColorScheme()
        }
    }

    override fun onPause() {
        monitoringView?.visibility(Visibility.HIDDEN)
        // LYNX_DEBUG_TOOL_BEGIN
        LynxDebugBridge.updateVisibility(lynxView, "hidden")
        // LYNX_DEBUG_TOOL_END
        lynxView?.onEnterBackground()
        super.onPause()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        syncColorScheme()
    }

    override fun onDestroyView() {
        LynxRouter.removeOtaUserContextListener(userContextListener)
        LynxEnvironmentCoordinator.unbind(lynxView)
        releaseContent(view as? ViewGroup)
        super.onDestroyView()
    }

    override fun onDestroy() {
        loader.shutdownNow()
        super.onDestroy()
    }

    /**
     * 用户主动刷新后重新读取本地候选或 current；方法名保留兼容。
     *
     * 这个方法不会触发网络请求；网络同步由宿主先显式执行，完成后再调用本方法。
     * 未显示的 Tab 也会被刷新，以便下一次切换时不保留旧 LynxView。
     */
    fun refreshFromCurrent() {
        if (!isAdded) return
        val host = view as? ViewGroup ?: return
        releaseContent(host)
        otaRecoveryUsed = false
        loadContent(host)
    }

    private fun loadContent(host: ViewGroup, stableRecovery: Boolean = false) {
        val activity = activity ?: return
        val runtime = LynxShell.activityBundleRuntime()
        val epoch = runtime?.userIdentityEpoch
        preparedRuntime = runtime
        preparedUserEpoch = epoch
        otaHealthGate = LynxOtaHealthGate()
        loadFailureHandledGeneration = null
        val generation = ++loadGeneration
        loadCount += 1
        monitoringView = LynxMonitor.reserve(
            ContainerKind.TAB,
            if (loadCount == 1) LoadKind.INITIAL else LoadKind.RELOAD,
            BundleIdentities.attempted(spec.bundleUrl, spec.lynxAppId, spec.bundleName),
            if (isResumed && !isHidden) Visibility.VISIBLE else Visibility.HIDDEN,
        )
        val monitoring = monitoringView
        debugError = "loading"
        loadFuture = loader.submit {
            val appId = spec.lynxAppId
            val bundleName = spec.bundleName
            val result = runCatching {
                if (appId != null && bundleName != null) {
                    if (stableRecovery) runtime?.resolveRecoveredCurrent(appId, bundleName, null)
                    else runtime?.resolvePage(appId, bundleName)
                } else null
            }
            val resolved = result.getOrNull()
            if (Thread.currentThread().isInterrupted || result.exceptionOrNull() is InterruptedException ||
                result.exceptionOrNull() is CancellationException) {
                runCatching { resolved?.releaseLease?.close() }
                return@submit
            }
            activity.runOnUiThread {
                if (!isAdded || view !== host || generation != loadGeneration ||
                    (spec.lynxAppId != null && (runtime !== LynxShell.activityBundleRuntime() || epoch != runtime?.userIdentityEpoch ||
                        (resolved?.userIdentityEpoch != null && resolved.userIdentityEpoch != runtime?.userIdentityEpoch)))) {
                    runCatching { resolved?.releaseLease?.close() }
                    return@runOnUiThread
                }
                loadFuture = null
                if (result.isFailure) {
                    showError(host, "Tab 本地读取失败：${result.exceptionOrNull()?.javaClass?.simpleName}")
                } else if (spec.lynxAppId != null && resolved == null) {
                    showError(host, "Tab ${spec.tabId} 没有可用的 active Bundle；Tab 加载不会联网")
                } else {
                    resolved?.let { monitoring?.resolvePrepared(it) }
                    debugIdentity = "release=${resolved?.releaseId ?: "none"};source=${resolved?.source ?: "direct_asset"};kind=${resolved?.selectionKind ?: "embedded"};sequence=${resolved?.releaseSequence ?: "none"};epoch=${resolved?.userIdentityEpoch ?: 0}"
                    render(
                        generation = generation,
                        host = host,
                        preparedFile = resolved?.file,
                        preparedBytes = resolved?.bytes,
                        nextReleaseLease = resolved?.releaseLease,
                        sidecarResources = resolved?.sidecarResources,
                        preparedBundle = resolved,
                        bundleMetadata = resolved?.let {
                            mapOf(
                                "lynxAppId" to it.lynxAppId,
                                "releaseId" to (it.releaseId ?: "unknown"),
                                // Bundle 的真实来源仍由 Runtime 决定；cache-only 是读取策略，
                                // 不应该覆盖 ota_current / embedded_baseline 这类来源信息。
                                "source" to it.source,
                                "loadPolicy" to "cache_only",
                                "bundleName" to it.bundleName,
                                "sha256" to (it.sha256 ?: ""),
                                "selectionKind" to (it.selectionKind ?: "embedded"),
                                "releaseSequence" to (it.releaseSequence ?: ""),
                                "userIdentityEpoch" to (it.userIdentityEpoch ?: 0L),
                            )
                        },
                    )
                }
            }
        }
    }

    private fun releaseContent(host: ViewGroup?) {
        monitoringView?.close("cancelled")
        monitoringView = null
        loadGeneration += 1
        loadFuture?.cancel(true)
        loadFuture = null
        cancelOtaHealth("Tab 内容已释放")
        firstScreenReady = false
        debugIdentity = ""
        bundleRuntimeMetadata = null
        preparedRuntime = null
        preparedUserEpoch = null
        unregister()
        templateProvider?.close()
        templateProvider = null
        LynxEnvironmentCoordinator.unbind(lynxView)
        // LYNX_DEBUG_TOOL_BEGIN
        LynxDebugBridge.detach(lynxView)
        // LYNX_DEBUG_TOOL_END
        lynxView?.let(LynxShell::destroyView)
        lynxView = null
        releaseCurrentLease()
        host?.removeAllViews()
    }

    private fun render(
        generation: Long,
        host: ViewGroup,
        preparedFile: java.io.File?,
        preparedBytes: ByteArray?,
        nextReleaseLease: AutoCloseable?,
        sidecarResources: com.ota.android.sdk.OtaSidecarViewResources? = null,
        bundleMetadata: Map<String, Any>? = null,
        preparedBundle: com.example.lynxshell.ota.PreparedActivityBundle? = null,
    ) {
        val activity = activity ?: run {
            runCatching { nextReleaseLease?.close() }
            return
        }
        replaceReleaseLease(nextReleaseLease)
        bundleRuntimeMetadata = bundleMetadata
        renderCount += 1
        val request = LynxPageRequest(
            bundleUrl = spec.bundleUrl,
            lynxAppId = spec.lynxAppId,
            bundleName = spec.bundleName,
            routeKey = spec.routeKey,
            title = spec.title,
            initDataJson = spec.initDataJson,
            globalPropsJson = spec.globalPropsJson,
            fullscreen = true,
            showToolbar = false,
            hideStatusBar = false,
            backGestureEnabled = true,
            allowHttpInDebug = false,
            orientation = PageOrientation.SYSTEM,
            keyboardBehavior = KeyboardBehavior.SYSTEM,
            backgroundColor = spec.backgroundColor,
        ).validated()
        val provider = ShellTemplateProvider(
            context = activity.applicationContext,
            preparedUrl = request.bundleUrl,
            preparedFile = preparedFile,
            preparedBytes = preparedBytes,
            monitoring = monitoringView,
            onLoadError = { _, message ->
                activity.runOnUiThread {
                    if (isAdded && view === host && generation == loadGeneration) handleLoadFailure(host, generation, message)
                }
            },
        )
        templateProvider = provider
        val markFirstFrame = {
            activity.runOnUiThread {
                if (isAdded && view === host && generation == loadGeneration) {
                    firstScreenReady = true
                    otaHealthGate.markFirstScreen()
                    debugError = "ready"
                    confirmCandidateHealthyIfNeeded(host, generation)
                }
            }
        }
        val client = object : LynxViewClient() {
            override fun onFirstScreen() {
                markFirstFrame()
            }
            override fun onReceivedError(error: LynxError) {
                val failure = LynxLoadFailure(error.errorCode, error.subCode, error.isFatal, error.level, error.msg)
                if (!failure.requiresErrorState) return
                activity.runOnUiThread {
                    handleLoadFailure(host, generation, "Lynx Tab 失败（${failure.code}/${failure.subCode}）：${failure.message}")
                }
            }
        }
        val created = LynxContainerFactory.create(
            activity = activity,
            request = request,
            templateProvider = provider,
            lynxViewClient = client,
            bundleMetadata = bundleMetadata,
            sidecarResources = sidecarResources,
            monitoring = monitoringView,
            preparedBundle = preparedBundle,
            pageInfo = LynxRouterPageInfo(pageID, pageID, spec.routeKey, "android_fragment"),
            onCachedFrame = { markFirstFrame() },
            // LYNX_DEBUG_TOOL_BEGIN
            containerKind = "tab",
            // LYNX_DEBUG_TOOL_END
        )
        lynxView = created
        host.addView(
            created,
            0,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
        val owner = WeakReference(this)
        val source = WeakReference(created)
        val hostReference = WeakReference(host)
        ShellMessageHub.register(
            info = LynxRouterPageInfo(
                pageId = pageID,
                containerId = pageID,
                pageKey = spec.routeKey,
                hostMode = "android_fragment",
            ),
            activity = activity,
            view = created,
            otaHealthHandler = { completion ->
                val fragment = owner.get()
                val sourceView = source.get()
                val contentHost = hostReference.get()
                if (fragment == null || sourceView == null || contentHost == null) completion(LynxOtaHealthReply(1002, "Tab 页面已销毁"))
                else fragment.markOtaHealthy(sourceView, contentHost, generation, completion)
            },
        )
        LynxEnvironmentCoordinator.bind(activity, created)
        if (isResumed && !isHidden) LynxShell.nativeModuleHost()?.onViewActive(activity, created)
        created.renderTemplateUrl(
            request.bundleUrl,
            JsonObjectCodec.toMap(request.initDataJson, "initData"),
        )
    }

    private fun isCurrentContent(host: ViewGroup, generation: Long): Boolean =
        isAdded && view === host && generation == loadGeneration

    private fun isPreparedUserCurrent(): Boolean =
        preparedRuntime === LynxShell.activityBundleRuntime() && preparedUserEpoch == preparedRuntime?.userIdentityEpoch

    private fun markOtaHealthy(sourceView: LynxView, host: ViewGroup, generation: Long, completion: LynxOtaHealthCompletion) {
        if (!isCurrentContent(host, generation) || sourceView !== lynxView || otaHealthGate.failed ||
            (spec.lynxAppId != null && !isPreparedUserCurrent())) {
            completion(LynxOtaHealthReply(1002, "Tab 页面或 OTA 身份已失效"))
            return
        }
        val metadata = bundleRuntimeMetadata
        if (otaHealthGate.confirmed) {
            completion(LynxOtaHealthReply(0, data = mapOf("confirmed" to true, "releaseId" to metadata?.get("releaseId"))))
        } else if (metadata?.get("source") != "candidate_trial") {
            completion(LynxOtaHealthReply(0, data = mapOf("confirmed" to false, "reason" to "not_candidate")))
        } else if (pendingHealthCompletion != null || otaHealthGate.confirming) {
            completion(LynxOtaHealthReply(1006, "Tab 健康确认正在等待首屏或提交"))
        } else {
            pendingHealthCompletion = completion
            otaHealthGate.markBusinessHealth()
            confirmCandidateHealthyIfNeeded(host, generation)
        }
    }

    private fun confirmCandidateHealthyIfNeeded(host: ViewGroup, generation: Long) {
        if (!isCurrentContent(host, generation) || !isPreparedUserCurrent() || pendingHealthCompletion == null) return
        val metadata = bundleRuntimeMetadata ?: return
        if (metadata["source"] != "candidate_trial" || !otaHealthGate.beginConfirmation()) return
        val appId = spec.lynxAppId ?: return
        val runtime = preparedRuntime ?: return
        val epoch = preparedUserEpoch
        val releaseId = metadata["releaseId"] as? String
        val sourceView = lynxView
        val activity = activity ?: return
        healthFuture = loader.submit {
            val result = runCatching { runtime.confirmCandidateHealthy(appId, releaseId, epoch) }
            if (Thread.currentThread().isInterrupted || result.exceptionOrNull() is InterruptedException ||
                result.exceptionOrNull() is CancellationException) return@submit
            activity.runOnUiThread {
                if (!isCurrentContent(host, generation) || sourceView !== lynxView || !isPreparedUserCurrent() || otaHealthGate.failed) return@runOnUiThread
                healthFuture = null
                val completion = pendingHealthCompletion
                pendingHealthCompletion = null
                if (result.getOrNull() == true && otaHealthGate.completeConfirmation()) {
                    bundleRuntimeMetadata = metadata + mapOf("source" to "ota_current", "promoted" to true)
                    debugIdentity = debugIdentity.replace("source=candidate_trial", "source=ota_current")
                    completion?.invoke(LynxOtaHealthReply(0, data = mapOf("confirmed" to true, "releaseId" to releaseId)))
                } else {
                    otaHealthGate.fail()
                    completion?.invoke(LynxOtaHealthReply(1003, result.exceptionOrNull()?.message ?: "Tab 候选版本健康确认已失效"))
                }
            }
        }
    }

    private fun cancelOtaHealth(message: String, code: Int = 1002) {
        otaHealthGate.fail()
        healthFuture?.cancel(true)
        healthFuture = null
        val completion = pendingHealthCompletion
        pendingHealthCompletion = null
        completion?.invoke(LynxOtaHealthReply(code, message))
    }

    private fun handleLoadFailure(host: ViewGroup, generation: Long, message: String) {
        if (!isCurrentContent(host, generation) || loadFailureHandledGeneration == generation) return
        com.example.lynxshell.container.LynxTemplateGroupCache.reject(lynxView)
        loadFailureHandledGeneration = generation
        val appId = spec.lynxAppId
        val runtime = preparedRuntime
        val epoch = preparedUserEpoch
        val releaseId = bundleRuntimeMetadata?.get("releaseId") as? String
        val failedCandidate = bundleRuntimeMetadata?.get("source") == "candidate_trial"
        val canRecover = !otaRecoveryUsed && !otaHealthGate.confirmed &&
            (failedCandidate || !firstScreenReady) && appId != null && runtime != null && isPreparedUserCurrent()
        showError(host, message)
        if (!canRecover) return
        otaRecoveryUsed = true
        val activity = activity ?: return
        loadFuture = loader.submit {
            val result = runCatching {
                if (failedCandidate) runtime!!.recoverFailedCandidate(appId!!, releaseId, epoch)
                else runtime!!.rollback(appId!!, message, releaseId, epoch)
            }
            if (Thread.currentThread().isInterrupted || result.exceptionOrNull() is InterruptedException ||
                result.exceptionOrNull() is CancellationException) return@submit
            activity.runOnUiThread {
                if (!isCurrentContent(host, generation) || !isPreparedUserCurrent()) return@runOnUiThread
                loadFuture = null
                if (result.getOrNull() == true) {
                    releaseContent(host)
                    loadContent(host, stableRecovery = true)
                } else {
                    showError(host, "$message；${result.exceptionOrNull()?.message ?: "没有稳定 Bundle 可恢复"}")
                }
            }
        }
    }

    private fun showError(host: ViewGroup, message: String) {
        cancelOtaHealth("Tab 已进入错误态", 1002)
        unregister()
        monitoringView?.failed("tab_load_failed")
        monitoringView?.close("load_failed")
        monitoringView = null
        debugError = message
        debugIdentity = ""
        templateProvider?.close()
        templateProvider = null
        LynxEnvironmentCoordinator.unbind(lynxView)
        // LYNX_DEBUG_TOOL_BEGIN
        LynxDebugBridge.detach(lynxView)
        // LYNX_DEBUG_TOOL_END
        lynxView?.let(LynxShell::destroyView)
        lynxView = null
        releaseCurrentLease()
        host.removeViews(0, host.childCount)
        host.addView(TextView(requireContext()).apply {
            text = message
            textSize = 14f
            setTextColor(android.graphics.Color.DKGRAY)
            setPadding(32)
            gravity = android.view.Gravity.CENTER
        }, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
    }

    /** 宿主不重建 Fragment 时，保持引擎 media query 与既有 theme 字段同源。 */
    private fun syncColorScheme() {
        val activity = activity ?: return
        LynxEnvironmentCoordinator.synchronize(activity)
    }

    private fun unregister() {
        if (pageID.isNotBlank()) ShellMessageHub.unregister(pageID)
    }

    private fun replaceReleaseLease(next: AutoCloseable?) {
        if (releaseLease === next) return
        releaseCurrentLease()
        releaseLease = next
    }

    private fun releaseCurrentLease() {
        val current = releaseLease
        releaseLease = null
        runCatching { current?.close() }
    }

    companion object {
        private const val ARG_TAB_ID = "lynx.tab.id"
        private const val ARG_BUNDLE_URL = "lynx.tab.bundle.url"
        private const val ARG_TITLE = "lynx.tab.title"
        private const val ARG_ROUTE_KEY = "lynx.tab.route.key"
        private const val ARG_INIT_DATA = "lynx.tab.init.data"
        private const val ARG_GLOBAL_PROPS = "lynx.tab.global.props"
        private const val ARG_APP_ID = "lynx.tab.app.id"
        private const val ARG_BUNDLE_NAME = "lynx.tab.bundle.name"
        private const val ARG_BACKGROUND = "lynx.tab.background"

        fun newInstance(spec: LynxTabSpec): LynxTabFragment = LynxTabFragment().apply {
            arguments = Bundle().apply {
                putString(ARG_TAB_ID, spec.tabId)
                putString(ARG_BUNDLE_URL, spec.bundleUrl)
                putString(ARG_TITLE, spec.title)
                putString(ARG_ROUTE_KEY, spec.routeKey)
                putString(ARG_INIT_DATA, spec.initDataJson)
                putString(ARG_GLOBAL_PROPS, spec.globalPropsJson)
                putString(ARG_APP_ID, spec.lynxAppId)
                putString(ARG_BUNDLE_NAME, spec.bundleName)
                putString(ARG_BACKGROUND, spec.backgroundColor)
            }
        }
    }
}
