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
import com.example.lynxshell.bridge.LynxRouterPageInfo
import com.example.lynxshell.bridge.ShellMessageHub
import com.example.lynxshell.container.LynxContainerFactory
import com.example.lynxshell.model.KeyboardBehavior
import com.example.lynxshell.model.LynxPageRequest
import com.example.lynxshell.model.PageOrientation
import com.example.lynxshell.resource.ShellTemplateProvider
import com.example.lynxshell.runtime.ShellGlobalPropsFactory
import com.example.lynxshell.util.JsonObjectCodec
import com.lynx.tasm.LynxError
import com.lynx.tasm.LynxView
import com.lynx.tasm.LynxViewClient
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future

/**
 * 无 TabBar 的 Android Lynx 内容承载能力。
 *
 * Fragment 不负责选中态、BottomNavigation 或业务 Tab 顺序；宿主可以用任意原生导航控件
 * 组合它。OTA Tab 只调用 ActivityBundleRuntime.resolveCurrent，禁止在切 Tab 时联网。
 */
class LynxTabFragment : Fragment() {
    private lateinit var spec: LynxTabSpec
    private var lynxView: LynxView? = null
    private var templateProvider: ShellTemplateProvider? = null
    private var releaseLease: AutoCloseable? = null
    private var pageID: String = ""
    @Volatile
    private var loadGeneration: Long = 0L
    private var loadFuture: Future<*>? = null
    private var firstScreenReady = false
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
        if (hidden) {
            lynxView?.onEnterBackground()
        } else {
            lynxView?.onEnterForeground()
            syncColorScheme()
        }
    }

    override fun onResume() {
        super.onResume()
        if (!isHidden) {
            lynxView?.onEnterForeground()
            syncColorScheme()
        }
    }

    override fun onPause() {
        lynxView?.onEnterBackground()
        super.onPause()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        syncColorScheme()
    }

    override fun onDestroyView() {
        LynxRouter.removeOtaUserContextListener(userContextListener)
        releaseContent(view as? ViewGroup)
        super.onDestroyView()
    }

    override fun onDestroy() {
        loader.shutdownNow()
        super.onDestroy()
    }

    /**
     * 用户主动刷新后重新读取已经提交的 OTA current。
     *
     * 这个方法不会触发网络请求；网络同步由宿主先显式执行，完成后再调用本方法。
     * 未显示的 Tab 也会被刷新，以便下一次切换时不保留旧 LynxView。
     */
    fun refreshFromCurrent() {
        if (!isAdded) return
        val host = view as? ViewGroup ?: return
        releaseContent(host)
        loadContent(host)
    }

    private fun loadContent(host: ViewGroup) {
        val activity = activity ?: return
        val runtime = LynxShell.activityBundleRuntime()
        val epoch = runtime?.userIdentityEpoch
        val generation = ++loadGeneration
        loadCount += 1
        debugError = "loading"
        loadFuture = loader.submit {
            val appId = spec.lynxAppId
            val bundleName = spec.bundleName
            val result = runCatching {
                if (appId != null && bundleName != null) runtime?.resolveCurrent(appId, bundleName) else null
            }
            val resolved = result.getOrNull()
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
                    debugIdentity = "release=${resolved?.releaseId ?: "none"};source=${resolved?.source ?: "direct_asset"};kind=${resolved?.selectionKind ?: "embedded"};sequence=${resolved?.releaseSequence ?: "none"};epoch=${resolved?.userIdentityEpoch ?: 0}"
                    render(
                        generation = generation,
                        host = host,
                        preparedFile = resolved?.file,
                        preparedBytes = resolved?.bytes,
                        nextReleaseLease = resolved?.releaseLease,
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
        loadGeneration += 1
        loadFuture?.cancel(true)
        loadFuture = null
        firstScreenReady = false
        debugIdentity = ""
        unregister()
        templateProvider?.close()
        templateProvider = null
        lynxView?.destroy()
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
        bundleMetadata: Map<String, Any>? = null,
    ) {
        val activity = activity ?: run {
            runCatching { nextReleaseLease?.close() }
            return
        }
        replaceReleaseLease(nextReleaseLease)
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
            onLoadError = { _, message ->
                activity.runOnUiThread {
                    if (isAdded && view === host && generation == loadGeneration && !firstScreenReady) showError(host, message)
                }
            },
        )
        templateProvider = provider
        val client = object : LynxViewClient() {
            override fun onFirstScreen() {
                activity.runOnUiThread {
                    if (isAdded && view === host && generation == loadGeneration) {
                        firstScreenReady = true
                        debugError = "ready"
                    }
                }
            }
            override fun onReceivedError(error: LynxError) {
                activity.runOnUiThread {
                    if (isAdded && view === host && generation == loadGeneration && !firstScreenReady) showError(host, "Lynx Tab 加载失败：$error")
                }
            }
        }
        val created = LynxContainerFactory.create(
            activity = activity,
            request = request,
            templateProvider = provider,
            lynxViewClient = client,
            bundleMetadata = bundleMetadata,
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
        ShellMessageHub.register(
            info = LynxRouterPageInfo(
                pageId = pageID,
                containerId = pageID,
                pageKey = spec.routeKey,
                hostMode = "android_fragment",
            ),
            activity = activity,
            view = created,
        )
        created.renderTemplateUrl(
            request.bundleUrl,
            JsonObjectCodec.toMap(request.initDataJson, "initData"),
        )
    }

    private fun showError(host: ViewGroup, message: String) {
        debugError = message
        debugIdentity = ""
        templateProvider?.close()
        templateProvider = null
        lynxView?.destroy()
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
        val view = lynxView ?: return
        view.updateColorScheme(ShellGlobalPropsFactory.resolveColorScheme(activity))
        view.updateGlobalProps(
            hashMapOf<String, Any>(
                "theme" to ShellGlobalPropsFactory.resolveThemeName(activity),
            ),
        )
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
