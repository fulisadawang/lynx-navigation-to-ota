package com.example.lynxshell.container

import android.content.pm.ActivityInfo
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.example.lynxshell.R
import com.example.lynxshell.LynxShell
import com.example.lynxshell.model.LynxPageRequest
import com.example.lynxshell.model.PageOrientation
import com.example.lynxshell.resource.ShellTemplateProvider
import com.example.lynxshell.bridge.LynxRouterPageInfo
import com.example.lynxshell.bridge.ShellMessageHub
import com.example.lynxshell.routing.LynxNavigator
import com.example.lynxshell.routing.LynxRouteParser
import com.example.lynxshell.transition.AndroidTransitionTicket
import com.example.lynxshell.transition.LynxTransitionCoordinator
import com.example.lynxshell.transition.LynxTransitionIntent
import com.example.lynxshell.transition.LynxTransitionRuntime
import com.example.lynxshell.transition.LynxTransitionSpec
import com.example.lynxshell.transition.LynxTransitionStatus
import com.example.lynxshell.transition.PreparedRouteStore
import com.example.lynxshell.ui.ShellErrorView
import com.example.lynxshell.ui.ShellLoadingView
import com.example.lynxshell.ota.ActivityBundleRuntime
import com.example.lynxshell.ota.PreparedActivityBundle
import com.example.lynxshell.telemetry.AttemptedBundleSnapshot
import com.example.lynxshell.telemetry.CoordinatorLynxTelemetryAdapter
import com.example.lynxshell.telemetry.PageLifecycleState
import com.example.lynxshell.telemetry.ResolvedBundleSnapshot
import com.example.lynxshell.telemetry.TelemetryBundleSource
import com.example.lynxshell.telemetry.TelemetryCoordinator
import com.example.lynxshell.telemetry.TelemetryCoordinatorRegistry
import com.example.lynxshell.telemetry.TelemetryHostContext
import com.example.lynxshell.telemetry.TelemetryIdentity
import com.example.lynxshell.util.JsonObjectCodec
import com.google.android.material.appbar.MaterialToolbar
import com.lynx.tasm.LynxError
import com.lynx.tasm.LynxView
import com.lynx.tasm.LynxViewClient
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future

/**
 * Android Lynx 页面容器。
 *
 * Activity 只处理页面生命周期、原生导航外观和错误态；Builder、Provider、
 * Router、Bridge 均在独立类中，便于替换为业务 App 自己的实现。
 */
class LynxShellActivity : AppCompatActivity() {
    private lateinit var container: FrameLayout
    private lateinit var toolbar: MaterialToolbar
    private lateinit var errorView: ShellErrorView
    private lateinit var loadingView: ShellLoadingView
    private lateinit var transitionRoot: FrameLayout
    private lateinit var transitionUnderlay: ImageView
    private lateinit var liveContent: ViewGroup
    private lateinit var transitionOverlay: FrameLayout
    private lateinit var transitionCoordinator: LynxTransitionCoordinator
    private lateinit var request: LynxPageRequest
    private var lynxView: LynxView? = null
    private var lynxViewClient: LynxViewClient? = null
    private var templateProvider: ShellTemplateProvider? = null
    private var contentGeneration = 0L
    private var rebuildAfterSnapshotRelease = false
    /** OTA prepare/rollback 任务；Activity 销毁或 replace 时必须取消。 */
    private var bundleFuture: Future<*>? = null
    /** 一个页面 generation 最多自动回滚一次，避免坏版本形成无限重试。 */
    private var otaRecoveryUsed = false
    /** 监控是旁路；默认 Noop Sink，不影响导航、OTA 或 Lynx 首屏。 */
    private lateinit var telemetryCoordinator: TelemetryCoordinator
    private lateinit var telemetryAdapter: CoordinatorLynxTelemetryAdapter
    private var telemetryGeneration: Long? = null
    private var telemetryFirstScreenReached = false
    private val otaExecutor: ExecutorService = Executors.newCachedThreadPool { runnable ->
        Thread(runnable, "lynx-shell-ota").apply { isDaemon = true }
    }
    private val disabledSystemBackCallback = object : OnBackPressedCallback(false) {
        override fun handleOnBackPressed() {
            // 页面显式关闭系统 Back 时只消费事件；原生 Toolbar 和 NativeModules.close
            // 仍可退出，避免把页面变成无法关闭的死路。
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        configureTransitionWindowAnimations()
        setContentView(R.layout.activity_lynx_shell)
        transitionRoot = findViewById(R.id.transition_root)
        transitionUnderlay = findViewById(R.id.transition_underlay)
        liveContent = findViewById(R.id.live_content)
        transitionOverlay = findViewById(R.id.transition_overlay)
        container = findViewById(R.id.lynx_container)
        toolbar = findViewById(R.id.shell_toolbar)
        errorView = ShellErrorView(this).also { view ->
            container.addView(
                view,
                FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT,
                ),
            )
        }
        loadingView = ShellLoadingView(this).also { view ->
            container.addView(
                view,
                FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT,
                ),
            )
        }

        val parsed = LynxRouteParser.parse(intent)
        if (parsed.isFailure) {
            configureFallbackChrome()
            errorView.show(parsed.exceptionOrNull()?.message ?: "无法解析页面路由")
            return
        }
        request = parsed.getOrThrow()
        // 登记 routeKey/sessionID 后，Native Module 才能执行 popTo/closeAll/redirect。
        LynxNavigator.register(this, request)
        initializeTelemetry()
        telemetryCoordinator.onNavigationAccepted()
        onBackPressedDispatcher.addCallback(this, disabledSystemBackCallback)
        configureWindow(request)
        transitionCoordinator = LynxTransitionCoordinator(
            activity = this,
            root = transitionRoot,
            underlay = transitionUnderlay,
            liveContent = liveContent,
            overlay = transitionOverlay,
            targetContent = container,
            restoredAfterRecreation = savedInstanceState != null,
            onSystemBackCommit = { LynxNavigator.commitSystemBack(this) },
        )
        transitionCoordinator.setBackGestureEnabled(request.backGestureEnabled)
        errorView.onRetry = { renderPage(resetOtaRecovery = true) }
        renderPage()
    }

    /**
     * 所有显式 transition/routeType 都由 Activity 内容层绘制。
     *
     * 这里不再按 style 分支：fade/slide/preset/fallback 同样必须关闭 Window open/close，
     * 否则系统动画会与自定义 renderer 叠加。
     */
    @Suppress("DEPRECATION")
    private fun configureTransitionWindowAnimations() {
        if (LynxTransitionIntent.transactionID(intent) == null) return
        if (Build.VERSION.SDK_INT >= 34) {
            overrideActivityTransition(
                OVERRIDE_TRANSITION_CLOSE,
                R.anim.lynx_no_animation,
                R.anim.lynx_no_animation,
            )
            overrideActivityTransition(
                OVERRIDE_TRANSITION_OPEN,
                R.anim.lynx_no_animation,
                R.anim.lynx_no_animation,
            )
        }
        overridePendingTransition(0, 0)
    }

    private fun configureFallbackChrome() {
        toolbar.title = "Lynx"
        toolbar.visibility = android.view.View.VISIBLE
        toolbar.setNavigationOnClickListener { requestToolbarBack() }
    }

    private fun configureWindow(request: LynxPageRequest) {
        disabledSystemBackCallback.isEnabled = !request.backGestureEnabled
        if (::transitionCoordinator.isInitialized) {
            transitionCoordinator.setBackGestureEnabled(request.backGestureEnabled)
        }
        requestedOrientation = when (request.orientation) {
            PageOrientation.PORTRAIT -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            PageOrientation.LANDSCAPE -> ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
            PageOrientation.SYSTEM -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }

        val background = Color.parseColor(request.backgroundColor)
        // fullscreen 表示 edge-to-edge：系统栏保持可见并透明覆盖在 Lynx 内容上。
        // hideStatusBar 是独立的显式能力，不能再由 fullscreen 隐式触发。
        window.statusBarColor = if (request.fullscreen) Color.TRANSPARENT else background
        window.navigationBarColor = if (request.fullscreen) Color.TRANSPARENT else background
        window.decorView.setBackgroundColor(background)
        WindowCompat.setDecorFitsSystemWindows(window, !request.fullscreen)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isStatusBarContrastEnforced = !request.fullscreen
            window.isNavigationBarContrastEnforced = !request.fullscreen
        }
        if (request.hideStatusBar) {
            // 只有页面显式请求隐藏时才使用 Window 级兜底。
            window.addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN)
        }
        WindowInsetsControllerCompat(window, window.decorView).apply {
            isAppearanceLightStatusBars = isLightColor(background)
            isAppearanceLightNavigationBars = isLightColor(background)
            if (request.hideStatusBar) {
                hide(WindowInsetsCompat.Type.statusBars())
            } else {
                show(WindowInsetsCompat.Type.statusBars())
            }
        }

        toolbar.title = request.title
        toolbar.visibility = if (request.showToolbar) android.view.View.VISIBLE else android.view.View.GONE
        toolbar.setNavigationOnClickListener { requestToolbarBack() }
        container.setBackgroundColor(background)
    }

    /**
     * 供 singleTop、singleTask 和 redirect 原位刷新当前 entry。
     *
     * 导航身份 extra 保留在原 Intent 中，只覆盖页面请求字段；旧 Provider/LynxView 会先
     * 释放再重建，因此不会让两个 Bundle 共用同一个 Runtime View。
     */
    fun replaceRequest(newRequest: LynxPageRequest) {
        bundleFuture?.cancel(true)
        request = newRequest.validated()
        request.writeTo(intent)
        configureWindow(request)
        renderPage()
    }

    private fun renderPage(resetOtaRecovery: Boolean = true) {
        bundleFuture?.cancel(true)
        bundleFuture = null
        if (resetOtaRecovery) otaRecoveryUsed = false
        errorView.hide()
        loadingView.hide()
        unregisterMessageEndpoint()
        templateProvider?.close()
        templateProvider = null
        lynxView?.let { oldView ->
            lynxViewClient?.let(oldView::removeLynxViewClient)
            container.removeView(oldView)
            oldView.destroy()
        }
        lynxView = null
        lynxViewClient = null
        contentGeneration += 1L
        val generation = contentGeneration
        beginTelemetryAttempt()

        val preparedToken = intent.getStringExtra(
            LynxTransitionIntent.EXTRA_PREPARED_ROUTE_TOKEN,
        )
        val preparedClaim = preparedToken?.let { token ->
            intent.removeExtra(LynxTransitionIntent.EXTRA_PREPARED_ROUTE_TOKEN)
            PreparedRouteStore.consume(token, request)
        }
        if (preparedClaim?.reason != null) {
            LynxTransitionIntent.transactionID(intent)?.let { transactionID ->
                val currentStatus = LynxTransitionRuntime.state(transactionID)?.status
                    ?: LynxTransitionStatus.DEGRADED
                LynxTransitionRuntime.update(
                    transactionID,
                    currentStatus,
                    reason = preparedClaim.reason,
                )
            }
        }

        // OTA prepare 必须先完成；这里不能提前创建空 LynxView，否则下载期间会出现白/黑闪烁。
        if (request.isOtaRequest()) {
            prepareOtaBundle(generation)
            return
        }

        renderPreparedPage(
            generation = generation,
            preparedBytes = preparedClaim?.bytes,
            preparedFile = null,
        )
    }

    /** 将已准备的来源交给 LynxView；普通 Assets/HTTPS 与 OTA 共用渲染链路。 */
    private fun renderPreparedPage(
        generation: Long,
        preparedBytes: ByteArray?,
        preparedFile: File?,
        preparedBundle: PreparedActivityBundle? = null,
    ) {
        resolveTelemetryBundle(preparedBundle, preparedFile)
        val provider = ShellTemplateProvider(
            context = applicationContext,
            allowHttpInDebug = request.allowHttpInDebug,
            preparedUrl = request.bundleUrl,
            preparedBytes = preparedBytes,
            preparedFile = preparedFile,
            onLoadError = { url, message ->
                runOnUiThread {
                    if (!isFinishing && !isDestroyed && url == request.bundleUrl) {
                        handleTemplateLoadFailure(generation, message)
                    }
                }
            },
        )
        templateProvider = provider

        runCatching {
            val client = object : LynxViewClient() {
                /**
                 * Lynx 4.0 正常以 onFirstScreen 为准；部分线程调度/厂商设备上
                 * onLoadSuccess 可能成为宿主 client 更稳定收到的同批次信号。
                 * Coordinator 内部按 generation 幂等，因此双信号不会启动两次动画。
                 */
                private fun notifyTargetVisualReady() {
                    runOnUiThread {
                        if (!isFinishing && !isDestroyed) {
                            if (isCurrentGeneration(generation)) loadingView.hide()
                            telemetryGeneration?.let { telemetryGenerationId ->
                                if (telemetryAdapter.onFirstScreen(telemetryGenerationId)) {
                                    telemetryFirstScreenReached = true
                                }
                            }
                            transitionCoordinator.onFirstScreen(
                                lynxView = lynxView ?: return@runOnUiThread,
                                generation = generation,
                            )
                        }
                    }
                }

                override fun onFirstScreen() {
                    notifyTargetVisualReady()
                }

                override fun onLoadSuccess() {
                    notifyTargetVisualReady()
                }

                override fun onReceivedError(error: LynxError) {
                    runOnUiThread {
                        if (!isFinishing && !isDestroyed) {
                            telemetryGeneration?.let { telemetryCoordinator.failRender(it, "lynx_received_error") }
                            transitionCoordinator.onLoadError()
                        }
                    }
                }
            }
            val view = LynxContainerFactory.create(
                activity = this,
                request = request,
                templateProvider = provider,
                lynxViewClient = client,
            )
            // 错误 View 已经在容器中，因此 LynxView 插到最底层。
            container.addView(
                view,
                0,
                FrameLayout.LayoutParams(
                    request.widthPx ?: ViewGroup.LayoutParams.MATCH_PARENT,
                    request.heightPx ?: ViewGroup.LayoutParams.MATCH_PARENT,
                ),
            )
            lynxView = view
            lynxViewClient = client
            registerMessageEndpoint(view)
            transitionCoordinator.onPageGenerationChanged(view, generation)
            val initData = JsonObjectCodec.toMap(request.initDataJson, "initData")
            view.renderTemplateUrl(request.bundleUrl, initData)
        }.onFailure { error ->
            provider.close()
            if (templateProvider === provider) templateProvider = null
            handleTemplateLoadFailure(generation, error.message ?: "LynxView 创建失败")
        }
    }

    /** 在创建 LynxView 前等待 OTA SDK 完成 current 解析、下载、校验和激活。 */
    private fun prepareOtaBundle(generation: Long) {
        val appId = request.lynxAppId
        val bundleName = request.bundleName
        val runtime: ActivityBundleRuntime? = LynxShell.activityBundleRuntime()
        if (appId.isNullOrBlank() || bundleName.isNullOrBlank() || runtime == null) {
            handleTemplateLoadFailure(generation, "OTA 页面未配置 ActivityBundleRuntime")
            return
        }

        loadingView.show("正在检查 $appId/$bundleName…")
        bundleFuture = otaExecutor.submit {
            val result = runCatching { runtime.prepare(appId, bundleName) }
            runOnUiThread {
                if (!isCurrentGeneration(generation)) return@runOnUiThread
                bundleFuture = null
                result.fold(
                    onSuccess = { prepared ->
                        val checked = runCatching {
                            require(prepared.lynxAppId == appId) {
                                "OTA prepare 返回了错误的 lynxAppId"
                            }
                            require(prepared.bundleName == bundleName) {
                                "OTA prepare 返回了错误的 bundleName"
                            }
                            prepared
                        }
                        checked.fold(
                            onSuccess = { value ->
                                renderPreparedPage(
                                    generation = generation,
                                    preparedBytes = value.bytes,
                                    preparedFile = value.file,
                                    preparedBundle = value,
                                )
                            },
                            onFailure = { error ->
                                handleTemplateLoadFailure(
                                    generation,
                                    error.message ?: "OTA Bundle 身份校验失败",
                                )
                            },
                        )
                    },
                    onFailure = { error ->
                        telemetryGeneration?.let {
                            telemetryCoordinator.failPrepare(it, error.message ?: "ota_prepare_failed")
                        }
                        handleTemplateLoadFailure(
                            generation,
                            error.message ?: "OTA Bundle 准备失败",
                        )
                    },
                )
            }
        }
    }

    /** 根 Bundle prepare/首屏失败时按 appId 回滚一次并重新准备。 */
    private fun handleTemplateLoadFailure(generation: Long, message: String) {
        if (!isCurrentGeneration(generation)) return
        telemetryGeneration?.let {
            if (request.isOtaRequest() && telemetryCoordinator.currentResolvedSnapshot() == null) {
                telemetryCoordinator.failPrepare(it, message)
            } else {
                telemetryCoordinator.failRender(it, message)
            }
        }
        loadingView.hide()
        if (request.isOtaRequest() && attemptOtaRecovery(generation, message)) return
        if (::transitionCoordinator.isInitialized) transitionCoordinator.onLoadError()
        errorView.show(message)
    }

    private fun attemptOtaRecovery(generation: Long, reason: String): Boolean {
        if (otaRecoveryUsed) return false
        val appId = request.lynxAppId ?: return false
        val runtime = LynxShell.activityBundleRuntime() ?: return false
        otaRecoveryUsed = true
        loadingView.show("页面加载失败，正在回滚…")
        bundleFuture = otaExecutor.submit {
            val result = runCatching { runtime.rollback(appId, reason) }
            runOnUiThread {
                if (!isCurrentGeneration(generation)) return@runOnUiThread
                bundleFuture = null
                if (result.getOrNull() == true) {
                    // 保留 otaRecoveryUsed=true，禁止坏版本再次失败后形成无限回滚循环。
                    renderPage(resetOtaRecovery = false)
                } else {
                    val rollbackMessage = result.exceptionOrNull()?.message
                        ?: "OTA 回滚后没有可用 Bundle"
                    loadingView.hide()
                    if (::transitionCoordinator.isInitialized) transitionCoordinator.onLoadError()
                    errorView.show("$reason；$rollbackMessage")
                }
            }
        }
        return true
    }

    private fun isCurrentGeneration(generation: Long): Boolean =
        generation == contentGeneration && !isFinishing && !isDestroyed

    /** Navigator/转场层只读当前 generation 的 LynxView，不持有跨 Activity 强引用。 */
    fun currentLynxView(): LynxView? = lynxView

    /**
     * maintainState=false 的 Android 近似实现。
     *
     * Runtime 已经冻结 Window 后销毁源 LynxView/Provider；Activity 身份仍留在返回栈，
     * 回来时按原 request 重建。这样释放大部分 Lynx Runtime 资源，同时不破坏 Android
     * Activity back stack。若当前尚无 LynxView，返回 false 让 Runtime 写明降级 reason。
     */
    internal fun releaseContentForRouteSnapshot(): Boolean {
        val view = lynxView ?: return false
        templateProvider?.close()
        templateProvider = null
        lynxViewClient?.let(view::removeLynxViewClient)
        container.removeView(view)
        view.destroy()
        lynxView = null
        lynxViewClient = null
        rebuildAfterSnapshotRelease = true
        return true
    }

    /** startActivity 失败时立即恢复；正常路径则由 onResume 恢复。 */
    internal fun restoreContentReleasedForRouteSnapshot() {
        if (!rebuildAfterSnapshotRelease || isFinishing || isDestroyed) return
        rebuildAfterSnapshotRelease = false
        renderPage()
    }

    /**
     * Navigator 发起普通或批量 pop 时进入同一状态机；返回 false 表示当前有事务在执行。
     */
    fun requestNavigationBack(
        animated: Boolean,
        useStoredTransition: Boolean,
        transitionSpecOverride: LynxTransitionSpec? = null,
        snapshotTicket: AndroidTransitionTicket? = null,
        forceTransaction: Boolean = false,
        routeKey: String? = null,
        transactionReason: String? = null,
        commit: () -> Unit,
    ): Boolean = transitionCoordinator.requestBack(
        animated = animated,
        useStoredTransition = useStoredTransition,
        transitionSpecOverride = transitionSpecOverride,
        snapshotTicket = snapshotTicket,
        forceTransaction = forceTransaction,
        routeKey = routeKey,
        transactionReason = transactionReason,
        commit = commit,
    )

    private fun requestToolbarBack() {
        if (!::transitionCoordinator.isInitialized) {
            // 路由解析失败等极早期错误页也复用 Navigator 的 finish 前后 suppress，
            // 避免显式 ticket 在异常分支重新出现系统 close 动画。
            LynxNavigator.commitSystemBack(this)
            return
        }
        val accepted = transitionCoordinator.requestBack(
            animated = true,
            useStoredTransition = true,
        ) {
            LynxNavigator.commitSystemBack(this)
        }
        if (!accepted) return
    }

    override fun onPause() {
        if (::telemetryCoordinator.isInitialized) {
            telemetryCoordinator.onPageLifecycle(PageLifecycleState.HIDDEN, "activity_on_pause")
        }
        routerPageId()?.let { pageId ->
            ShellMessageHub.sendLifecycle(pageId, "covered", "activity_on_pause")
        }
        if (::transitionCoordinator.isInitialized) transitionCoordinator.onPause()
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        restoreContentReleasedForRouteSnapshot()
        if (::telemetryCoordinator.isInitialized && telemetryFirstScreenReached) {
            telemetryCoordinator.onPageLifecycle(PageLifecycleState.VISIBLE, "activity_on_resume")
        }
        routerPageId()?.let { pageId ->
            ShellMessageHub.sendLifecycle(pageId, "active", "activity_on_resume")
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (::transitionCoordinator.isInitialized) {
            transitionCoordinator.onWindowFocusChanged(hasFocus)
        }
    }

    override fun onDestroy() {
        bundleFuture?.cancel(true)
        bundleFuture = null
        otaExecutor.shutdownNow()
        routerPageId()?.let { pageId ->
            if (isFinishing) {
                ShellMessageHub.sendLifecycle(pageId, "destroyed", "activity_on_destroy")
            }
            ShellMessageHub.unregister(pageId)
        }
        if (::transitionCoordinator.isInitialized) {
            transitionCoordinator.onDestroy(isChangingConfigurations)
        }
        if (::telemetryCoordinator.isInitialized) {
            if (isFinishing) {
                telemetryCoordinator.onPageLifecycle(PageLifecycleState.DESTROYED, "activity_on_destroy")
            } else {
                telemetryCoordinator.onPageLifecycle(PageLifecycleState.HIDDEN, "configurationChange")
            }
            TelemetryCoordinatorRegistry.unregister(telemetryCoordinator)
        }
        LynxNavigator.unregister(this)
        templateProvider?.close()
        templateProvider = null
        lynxView?.let { view ->
            lynxViewClient?.let(view::removeLynxViewClient)
            view.destroy()
        }
        lynxView = null
        lynxViewClient = null
        super.onDestroy()
    }

    /** 登记当前 Activity 对应的活体 LynxView；原位换 Bundle 时会重新登记。 */
    private fun registerMessageEndpoint(view: LynxView) {
        val identity = LynxNavigator.routerPageIdentity(this) ?: return
        ShellMessageHub.register(
            info = LynxRouterPageInfo(
                pageId = identity.entryID,
                containerId = identity.entryID,
                pageKey = identity.routeKey,
                hostMode = "android_activity",
            ),
            activity = this,
            view = view,
        )
    }

    private fun unregisterMessageEndpoint() {
        routerPageId()?.let(ShellMessageHub::unregister)
    }

    private fun routerPageId(): String? =
        LynxNavigator.routerPageIdentity(this)?.entryID

    /** 创建页面监控身份；页面参数、URL 和绝对路径不会进入 HostContext。 */
    private fun initializeTelemetry() {
        val routerIdentity = LynxNavigator.routerPageIdentity(this)
        val entryId = routerIdentity?.entryID ?: request.resolvedRouteKey()
        telemetryCoordinator = TelemetryCoordinator(
            pageIdentity = TelemetryIdentity.forPage(
                entryId = entryId,
                navigationSessionId = routerIdentity?.sessionID,
                transactionId = LynxTransitionIntent.transactionID(intent),
            ),
            hostContext = TelemetryHostContext(
                telemetryRouteKey = request.resolvedRouteKey(),
                hostMode = "activity",
                platform = "android",
            ),
        )
        telemetryAdapter = CoordinatorLynxTelemetryAdapter(telemetryCoordinator)
        TelemetryCoordinatorRegistry.register(telemetryCoordinator)
    }

    /** prepare 前冻结候选快照；replace/重试/回滚都会生成新的 attempt。 */
    private fun beginTelemetryAttempt() {
        if (!::telemetryCoordinator.isInitialized) return
        telemetryFirstScreenReached = false
        val bundleName = telemetryBundleName()
        telemetryGeneration = telemetryCoordinator.beginRenderAttempt(
            AttemptedBundleSnapshot(
                bundleSource = telemetryBundleSource(),
                lynxAppId = request.lynxAppId,
                bundleName = bundleName,
                telemetryRouteKey = request.resolvedRouteKey(),
                prepareStartedAtUnixMs = System.currentTimeMillis(),
                attemptGeneration = 0L,
            ),
        )
    }

    /** prepare 成功后冻结 resolved 快照；绝对路径仅用于当前进程交给 Provider。 */
    private fun resolveTelemetryBundle(
        prepared: PreparedActivityBundle?,
        preparedFile: File?,
    ) {
        val generation = telemetryGeneration ?: return
        val bundleName = telemetryBundleName()
        telemetryCoordinator.resolveBundle(
            generation,
            ResolvedBundleSnapshot(
                bundleSource = telemetryBundleSource(),
                lynxAppId = request.lynxAppId,
                bundleName = bundleName,
                telemetryRouteKey = request.resolvedRouteKey(),
                releaseId = prepared?.releaseId,
                bundleSha256 = prepared?.sha256,
                resolvedAtUnixMs = System.currentTimeMillis(),
                internalLocalPath = prepared?.file?.absolutePath ?: preparedFile?.absolutePath,
            ),
        )
    }

    private fun telemetryBundleSource(): TelemetryBundleSource = when {
        request.isOtaRequest() -> TelemetryBundleSource.OTA
        LynxPageRequest.isRemoteBundleUrl(request.bundleUrl) -> TelemetryBundleSource.DIRECT_HTTPS
        request.bundleUrl.startsWith("assets://", ignoreCase = true) ||
            request.bundleUrl.endsWith(".lynx.bundle", ignoreCase = true) -> TelemetryBundleSource.ASSETS
        else -> TelemetryBundleSource.LOCAL_FILE
    }

    /** Wire Schema 只接受文件名；完整路径仍保留在 Router/Provider 内部。 */
    private fun telemetryBundleName(): String {
        val logical = request.bundleName ?: request.bundleUrl
        val name = logical.substringAfterLast('/').substringAfterLast('\\')
        return if (name.endsWith(".lynx.bundle", ignoreCase = true)) name else "page.lynx.bundle"
    }

    private fun isLightColor(color: Int): Boolean {
        val luminance = (
            0.299 * Color.red(color) +
                0.587 * Color.green(color) +
                0.114 * Color.blue(color)
            ) / 255.0
        return luminance > 0.6
    }
}
