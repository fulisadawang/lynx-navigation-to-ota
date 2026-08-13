import Lynx
import UIKit

/**
 * 一个 Lynx 页面对应一个原生 UIViewController。
 *
 * 使用系统 UINavigationController，保留 iOS 标准 push/pop 动画和侧滑返回；
 * LynxView 的构造与加载由 LynxNativeRuntime 隔离。
 */
final class LynxContainerViewController: UIViewController {
    private(set) var request: LynxPageRequest
    let navigationSessionID: String
    let navigationEntryID: String
    let navigationParentEntryID: String?
    let navigationOrder: Int
    var routeKey: String { request.resolvedRouteKey }
    /** route preset 的 barrier 与 Lynx 内容分层，避免半屏/模态页面退栈后突然铺满全屏。 */
    private let barrierControl = UIControl()
    private let contentHostView = UIView()
    private var transitionBackdropView: UIView?
    private let errorView = ShellErrorView()
    private let loadingView = ShellLoadingView()
    private var lynxView: LynxView?
    private var templateProvider: ShellTemplateProvider?
    private var preparedBundleData: Data?
    private var loadGeneration = UUID()
    private var firstScreenObserver: LynxFirstScreenObserver?
    private var firstScreenReady = false
    private var firstScreenFailed = false
    private var readinessWaiters: [UUID: (Bool, String?) -> Void] = [:]
    private var otaPrepareTask: Task<Void, Never>?
    private var otaRecoveryUsed = false
    private var otaRecoveryInFlight = false
    /** Telemetry 只观察宿主事实，默认 Noop Sink，不改变 UIKit/Lynx 加载流程。 */
    private let telemetryCoordinator = LynxTelemetryCoordinator()
    private var telemetryHandle: LynxTelemetryPageHandle?
    private var telemetryRenderAttemptId: String?
    private var telemetryGeneration = 0

    init(
        request: LynxPageRequest,
        navigationSessionID: String,
        navigationEntryID: String = UUID().uuidString,
        navigationParentEntryID: String? = nil,
        navigationOrder: Int = 0,
        preparedBundleData: Data? = nil
    ) {
        self.request = request
        self.navigationSessionID = navigationSessionID
        self.navigationEntryID = navigationEntryID
        self.navigationParentEntryID = navigationParentEntryID
        self.navigationOrder = navigationOrder
        self.preparedBundleData = preparedBundleData
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("LynxContainerViewController 只允许通过 LynxPageRequest 初始化")
    }

    deinit {
        LynxTelemetryCoordinatorRegistry.unregister(telemetryCoordinator)
        ShellMessageHub.unregister(pageId: navigationEntryID)
        otaPrepareTask?.cancel()
        templateProvider?.cancel()
        finishReadiness(success: false, reason: "page_destroyed")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyChrome()
        initializeTelemetry()

        barrierControl.frame = view.bounds
        barrierControl.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        barrierControl.addTarget(
            self,
            action: #selector(didTapBarrier),
            for: .touchUpInside
        )
        view.addSubview(barrierControl)

        contentHostView.frame = view.bounds
        contentHostView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(contentHostView)

        errorView.translatesAutoresizingMaskIntoConstraints = false
        errorView.onRetry = { [weak self] in self?.rebuildLynxView(resetOtaRecovery: true) }
        contentHostView.addSubview(errorView)
        NSLayoutConstraint.activate([
            errorView.leadingAnchor.constraint(equalTo: contentHostView.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: contentHostView.trailingAnchor),
            errorView.topAnchor.constraint(equalTo: contentHostView.topAnchor),
            errorView.bottomAnchor.constraint(equalTo: contentHostView.bottomAnchor),
        ])

        loadingView.translatesAutoresizingMaskIntoConstraints = false
        loadingView.onCancel = { [weak self] in self?.cancelOtaPreparation() }
        contentHostView.addSubview(loadingView)
        NSLayoutConstraint.activate([
            loadingView.leadingAnchor.constraint(equalTo: contentHostView.leadingAnchor),
            loadingView.trailingAnchor.constraint(equalTo: contentHostView.trailingAnchor),
            loadingView.topAnchor.constraint(equalTo: contentHostView.topAnchor),
            loadingView.bottomAnchor.constraint(equalTo: contentHostView.bottomAnchor),
        ])
        layoutPresetContainer()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if telemetryHandle == nil { initializeTelemetry() }
        let animateChrome = animated &&
            ShellNavigator.shared.allowsSystemChromeAnimation(for: self)
        navigationController?.setNavigationBarHidden(
            request.fullscreen || !request.showNavigationBar,
            animated: animateChrome
        )
        ShellNavigator.shared.updateBackGesture(for: self)
        setNeedsStatusBarAppearanceUpdate()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        telemetryCoordinator.markPageHidden(
            navigationEntryID,
            reason: isMovingFromParent ? "detached" : "coveredByPage"
        )
        // UIKit 的 VC 生命周期是 iOS 端 Native Page Stack 的事实源；这里同步 Lynx
        // Runtime，而不是让页面自己猜测“被覆盖”和“被销毁”的区别。
        lynxView?.onEnterBackground()
        sendLifecycle(
            state: isMovingFromParent ? "detached" : "covered",
            reason: isMovingFromParent ? "uikit_view_will_disappear_pop" : "uikit_view_will_disappear_cover"
        )
        // 下一个页面会在自己的 viewWillAppear 中决定导航栏状态。
        if isMovingFromParent {
            let animateChrome = animated &&
                ShellNavigator.shared.allowsSystemChromeAnimation(for: self)
            navigationController?.setNavigationBarHidden(
                false,
                animated: animateChrome
            )
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        telemetryCoordinator.markPageVisible(navigationEntryID, reason: "uikit_view_did_appear")
        lynxView?.onEnterForeground()
        sendLifecycle(state: "active", reason: "uikit_view_did_appear")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent {
            telemetryCoordinator.markPageDestroyed(
                navigationEntryID,
                reason: "destroyed"
            )
            sendLifecycle(state: "destroyed", reason: "uikit_view_did_disappear_pop")
            ShellMessageHub.unregister(pageId: navigationEntryID)
            ShellNavigator.shared.entryDidClose(navigationEntryID)
        } else if !request.transitionSpec.routeConfig.maintainState,
                  navigationController?.topViewController !== self {
            // maintainState=false：离场动画用 snapshot，settle 后释放真实 LynxView。
            suspendLynxContent()
        }
        // 系统侧滑/导航栏 Back 不经过 Native Module；在生命周期回调中补一次快照同步。
        ShellNavigator.shared.navigationStackDidChange()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPresetContainer()
        if lynxView == nil,
           otaPrepareTask == nil,
           !firstScreenFailed,
           !otaRecoveryInFlight,
           contentHostView.bounds.width > 0,
           contentHostView.bounds.height > 0 {
            rebuildLynxView(resetOtaRecovery: true)
        } else if let lynxView {
            LynxNativeRuntime.updateLayout(view: lynxView, size: resolvedSize())
            // 旋转、分屏或状态栏变化后同步安全区和主题等系统参数。
            let globalProps = ShellGlobalPropsFactory.make(
                for: contentHostView,
                request: request,
                pageId: navigationEntryID,
                sessionId: navigationSessionID
            )
            LynxNativeRuntime.updateGlobalProps(globalProps, in: lynxView)
        }
    }

    override var prefersStatusBarHidden: Bool { request.hideStatusBar }
    override var preferredStatusBarStyle: UIStatusBarStyle {
        let background = UIColor(shellHex: request.backgroundColor) ?? .systemBackground
        return background.shellIsLightColor ? .darkContent : .lightContent
    }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        switch request.orientation {
        case .portrait: return .portrait
        case .landscape: return .landscape
        case .system: return .allButUpsideDown
        }
    }

    /**
     * singleTop、singleTask 和 redirect 复用当前 entry 时刷新页面请求。
     *
     * entryID/session/order/返回目标不变；旧 Provider 与 LynxView 会先释放，再按新请求
     * 创建，避免两个 Bundle 共享同一个 View 生命周期。
     */
    func replaceRequest(_ newRequest: LynxPageRequest) {
        request = newRequest
        guard isViewLoaded else { return }
        applyChrome()
        layoutPresetContainer()
        rebuildLynxView(resetOtaRecovery: true)
        setNeedsStatusBarAppearanceUpdate()
    }

    /** 当前 NativeModule 是否属于这个真实 Lynx 容器。 */
    func owns(_ candidate: LynxView?) -> Bool {
        guard let candidate, let lynxView else { return false }
        return candidate === lynxView
    }

    /**
     * 目标页首屏门禁。
     *
     * 该方法只预建 VC/LynxView，不修改 UINavigationController 栈。超时或失败仅使视觉
     * 转场降级，真实 open 仍会继续。
     */
    func waitUntilFirstScreen(
        timeoutMilliseconds: Int,
        completion: @escaping (Bool, String?) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        loadViewIfNeeded()
        if view.bounds.isEmpty {
            view.frame = UIScreen.main.bounds
        }
        view.setNeedsLayout()
        view.layoutIfNeeded()
        if lynxView == nil {
            rebuildLynxView(resetOtaRecovery: true)
        }
        if firstScreenReady {
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    completion(false, "page_destroyed")
                    return
                }
                self.view.layoutIfNeeded()
                completion(true, nil)
            }
            return
        }
        if firstScreenFailed {
            completion(false, "target_not_ready")
            return
        }

        let waiterID = UUID()
        readinessWaiters[waiterID] = completion
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(timeoutMilliseconds)
        ) { [weak self] in
            guard let self,
                  let waiter = self.readinessWaiters.removeValue(forKey: waiterID) else {
                return
            }
            waiter(false, "target_not_ready")
        }
    }

    /** 在 UIKit 主线程解析 Lynx idSelector 对应的真实 UIView。 */
    func resolveElement(idSelector: String) -> UIView? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard firstScreenReady,
              let element = lynxView?.view(withIdSelector: idSelector),
              !element.isHidden,
              element.alpha > 0.001,
              element.bounds.width > 0,
              element.bounds.height > 0,
              element.window != nil || isViewLoaded else {
            return nil
        }
        return element
    }

    /** 降级后立即刷新目标页可观察的 nativeTransition global prop。 */
    func updateNativeTransition(_ metadata: ShellNativeTransitionMetadata) {
        request = request.withNativeTransition(metadata)
        guard isViewLoaded, let lynxView else { return }
        LynxNativeRuntime.updateGlobalProps(
            ShellGlobalPropsFactory.make(
                for: contentHostView,
                request: request,
                pageId: navigationEntryID,
                sessionId: navigationSessionID
            ),
            in: lynxView
        )
    }

    /**
     * 路由真正提交后在 completed/degraded 收口时通知 JS。
     *
     * 该事件是 NativeModules 的异步完成通知，不参与逐帧动画；Worklet on-frame 在
     * Module-only 架构里没有同步调用通道，所有插值均留在 UIKit 主线程。
     */
    func sendRouteDone(_ payload: [String: Any]) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let lynxView else { return }
        // Skyline 生命周期：只有路由已提交（completed/degraded）才发送。
        lynxView.sendGlobalEvent("onRouteDone", withParams: [payload])
        // 旧 bundle 若仍监听历史事件名，继续收到同一份终态 payload。
        lynxView.sendGlobalEvent("lynxRouteDone", withParams: [payload])
    }

    /** 壳扩展终态事件：包括手势取消，适合业务恢复临时 hero/遮罩状态。 */
    func sendTransitionSettled(_ payload: [String: Any]) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let lynxView else { return }
        lynxView.sendGlobalEvent("onTransitionSettled", withParams: [payload])
    }

    /** ShellNavigationAnimator 操作的持久内容卡片，不直接改 LynxView 渲染树。 */
    var transitionContentView: UIView {
        loadViewIfNeeded()
        return contentHostView
    }

    /** preset route 的背景遮罩；动画完成后仍由目标 VC 持有。 */
    var transitionBarrierView: UIView {
        loadViewIfNeeded()
        return barrierControl
    }

    /**
     * 半屏页面已经进入导航栈后持有的来源页快照。
     *
     * 返回动画必须继续操作这张可见快照，而不是只操作已经被它遮住的上一层 VC，
     * 否则 bottom-sheet 关闭时背景页不会从“后退”状态自然恢复。
     */
    var transitionBackdropContentView: UIView? {
        loadViewIfNeeded()
        return transitionBackdropView
    }

    /**
     * UINavigationController 完成 push 后会移除 fromView。半屏/模态目标因此持有一张
     * 静态 backdrop，保证透明根视图后仍显示进入前页面，而不改变导航栈语义。
     * transform 与圆角用于保留进入动画的视觉终态，避免 push settle 后背景突然铺满。
     */
    func installTransitionBackdrop(
        _ snapshot: UIView,
        transform: CGAffineTransform = .identity,
        cornerRadius: CGFloat = 0
    ) {
        loadViewIfNeeded()
        transitionBackdropView?.removeFromSuperview()
        snapshot.frame = view.bounds
        snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        snapshot.layer.cornerCurve = .continuous
        snapshot.layer.cornerRadius = cornerRadius
        snapshot.clipsToBounds = cornerRadius > 0
        snapshot.transform = transform
        view.insertSubview(snapshot, at: 0)
        transitionBackdropView = snapshot
    }

    /** ShellNavigator 持久化栈时使用的 JSON 可序列化 entry 快照。 */
    var navigationSnapshot: [String: Any] {
        var value: [String: Any] = [
            "sessionID": navigationSessionID,
            "entryID": navigationEntryID,
            "order": navigationOrder,
            "request": request.navigationSnapshot,
        ]
        if let navigationParentEntryID {
            value["parentEntryID"] = navigationParentEntryID
        }
        return value
    }

    /** 初始化页面身份；Native 生成的 entry/pageView ID 不接受页面参数覆盖。 */
    private func initializeTelemetry() {
        guard telemetryHandle == nil else { return }
        let identity = LynxTelemetryIdentity(
            navigationSessionId: navigationSessionID,
            entryId: navigationEntryID
        )
        let attempted = makeTelemetryAttemptedSnapshot(generation: 1)
        telemetryHandle = telemetryCoordinator.startPage(
            identity: identity,
            attemptedBundle: attempted
        )
        LynxTelemetryCoordinatorRegistry.register(telemetryCoordinator)
        telemetryCoordinator.recordNavigationAdmission(
            navigationId: identity.navigationId,
            accepted: true,
            identity: identity
        )
    }

    /** prepare 前冻结候选信息；URL 只转换为低基数 Bundle 名称，不写入监控。 */
    private func makeTelemetryAttemptedSnapshot(generation: Int) -> LynxAttemptedBundleSnapshot {
        LynxAttemptedBundleSnapshot(
            source: telemetryBundleSource(),
            bundleName: telemetryBundleName(),
            telemetryRouteKey: request.resolvedRouteKey,
            lynxAppId: request.lynxAppId,
            prepareStartedAtUnixMs: Int64(Date().timeIntervalSince1970 * 1000),
            attemptGeneration: generation
        )
    }

    /** prepare/render 交付成功后冻结 resolved；绝对沙盒路径只用于当前 LynxView。 */
    private func resolveTelemetry(prepared: PreparedOtaBundle?, localPath: String?) {
        guard telemetryHandle != nil else { return }
        let snapshot = LynxResolvedBundleSnapshot(
            source: telemetryBundleSource(),
            bundleName: telemetryBundleName(),
            telemetryRouteKey: request.resolvedRouteKey,
            lynxAppId: request.lynxAppId,
            releaseId: prepared?.releaseId,
            bundleSha256: prepared?.sha256,
            resolvedAtUnixMs: Int64(Date().timeIntervalSince1970 * 1000),
            internalLocalPath: localPath
        )
        _ = telemetryCoordinator.resolve(
            pageViewId: navigationEntryID,
            snapshot: snapshot,
            renderAttemptId: telemetryRenderAttemptId,
            generation: telemetryGeneration
        )
    }

    private func telemetryBundleSource() -> LynxTelemetryBundleSource {
        if request.isOtaRequest { return .ota }
        if RemoteBundlePolicy.isRemote(request.bundleURL) { return .directHttps }
        if request.bundleURL.lowercased().hasPrefix("assets://") ||
            request.bundleURL.lowercased().hasSuffix(".lynx.bundle") {
            return .assets
        }
        return .localFile
    }

    private func telemetryBundleName() -> String {
        let logical = request.bundleName ?? request.bundleURL
        let path = logical.split(separator: "/").last.map(String.init) ?? logical
        return path.lowercased().hasSuffix(".lynx.bundle") ? path : "page.lynx.bundle"
    }

    private func applyChrome() {
        title = request.title
        navigationItem.largeTitleDisplayMode = .never
        let contentColor = UIColor(shellHex: request.backgroundColor) ?? .systemBackground
        contentHostView.backgroundColor = contentColor

        let routeType = request.transitionSpec.routeType
        let routeConfig = request.transitionSpec.routeConfig
        let isPartial = routeType?.isPartialContainer == true
        let opaque = routeConfig.opaque ?? !isPartial
        view.isOpaque = opaque
        view.backgroundColor = opaque ? contentColor : .clear
        barrierControl.backgroundColor = UIColor(
            shellHex: routeConfig.barrierColor ?? "#00000066"
        ) ?? UIColor.black.withAlphaComponent(0.4)
        barrierControl.isHidden = !isPartial || opaque
        barrierControl.isUserInteractionEnabled =
            isPartial && (routeConfig.barrierDismissible ?? true)
        barrierControl.isAccessibilityElement = barrierControl.isUserInteractionEnabled
        barrierControl.accessibilityTraits = .button
        barrierControl.accessibilityLabel = routeConfig.barrierLabel ?? "关闭页面"
        if routeType?.isPartialContainer != true {
            transitionBackdropView?.removeFromSuperview()
            transitionBackdropView = nil
        }
    }

    private func rebuildLynxView(resetOtaRecovery: Bool) {
        finishReadiness(success: false, reason: "page_destroyed")
        otaPrepareTask?.cancel()
        otaPrepareTask = nil
        loadGeneration = UUID()
        telemetryGeneration += 1
        let attempted = makeTelemetryAttemptedSnapshot(generation: telemetryGeneration)
        if let telemetryHandle {
            let identity = telemetryHandle.beginRenderAttempt(attempted: attempted)
            telemetryRenderAttemptId = identity.renderAttemptId
            telemetryGeneration = telemetryHandle.currentAttemptGeneration
        }
        if resetOtaRecovery {
            otaRecoveryUsed = false
            otaRecoveryInFlight = false
        }
        firstScreenReady = false
        firstScreenFailed = false
        loadingView.hide()
        errorView.hide()
        templateProvider?.cancel()
        templateProvider = nil
        ShellMessageHub.unregister(pageId: navigationEntryID)
        lynxView?.removeFromSuperview()
        lynxView = nil

        let generation = loadGeneration
        if request.isOtaRequest {
            prepareOtaBundle(generation: generation)
        } else {
            renderLynxView(generation: generation)
        }
    }

    /** OTA 页面先等待 current/下载/SHA/激活完成；等待期间不会创建空 LynxView。 */
    private func prepareOtaBundle(generation: UUID) {
        guard let appId = request.lynxAppId,
              let bundleName = request.bundleName else {
            handleTemplateLoadFailure(generation: generation, message: "OTA 路由缺少 lynxAppId 或 bundleName")
            return
        }
        guard let runtime = LynxShell.otaRuntime() else {
            handleTemplateLoadFailure(generation: generation, message: "OTA 页面未配置 Router 内置 OTA runtime")
            return
        }
        loadingView.show(message: "正在检查 \(appId)/\(bundleName)…")
        otaPrepareTask = Task { [weak self] in
            do {
                let prepared = try await runtime.prepare(lynxAppId: appId, bundleName: bundleName)
                try Task.checkCancellation()
                let data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: prepared.fileURL, options: .mappedIfSafe)
                }.value
                try Task.checkCancellation()
                await MainActor.run { [weak self] in
                    guard let self, generation == self.loadGeneration else { return }
                    self.otaPrepareTask = nil
                    guard prepared.lynxAppId == appId,
                          prepared.bundleName == bundleName,
                          !data.isEmpty else {
                        self.handleTemplateLoadFailure(
                            generation: generation,
                            message: "OTA Bundle 身份或内容校验失败"
                        )
                        return
                    }
                    self.preparedBundleData = data
                    self.resolveTelemetry(
                        prepared: prepared,
                        localPath: prepared.fileURL.path
                    )
                    self.loadingView.hide()
                    self.renderLynxView(generation: generation)
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, generation == self.loadGeneration else { return }
                    self.otaPrepareTask = nil
                    self.handleTemplateLoadFailure(
                        generation: generation,
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    /** 已准备字节和普通 assets/HTTPS 共用同一 LynxView 创建链。 */
    private func renderLynxView(generation: UUID) {
        guard generation == loadGeneration else { return }

        // Direct HTTPS/Assets 没有 OTA release，但仍需要一个已解析的 Bundle Snapshot，
        // 这样页面打开耗时可以按同一 pageView/attempt 关联。OTA 路径在 prepare 成功处已解析。
        if telemetryHandle?.resolvedBundle == nil {
            resolveTelemetry(prepared: nil, localPath: nil)
        }

        let provider = ShellTemplateProvider(
            allowHTTPInDebug: request.allowHTTPInDebug,
            onLoadError: { [weak self] url, error in
                guard let self, url == self.request.bundleURL else { return }
                self.handleTemplateLoadFailure(
                    generation: generation,
                    message: error.localizedDescription
                )
            },
            prefetchedURL: request.bundleURL,
            prefetchedData: preparedBundleData
        )
        preparedBundleData = nil
        templateProvider = provider

        let size = resolvedSize()
        let globalProps = ShellGlobalPropsFactory.make(
            for: contentHostView,
            request: request,
            pageId: navigationEntryID,
            sessionId: navigationSessionID
        )
        let createdView = LynxNativeRuntime.makeView(
            provider: provider,
            screenSize: size,
            globalProps: globalProps
        )
        let observer = LynxFirstScreenObserver(
            generation: generation,
            onFirstScreen: { [weak self] generation, view in
                self?.didReachFirstScreen(generation: generation, view: view)
            },
            onFirstScreenError: { [weak self] generation, view, error in
                self?.didFailBeforeFirstScreen(
                    generation: generation,
                    view: view,
                    error: error
                )
            }
        )
        firstScreenObserver = observer
        createdView.addLifecycleClient(observer)
        createdView.backgroundColor = contentHostView.backgroundColor
        contentHostView.insertSubview(createdView, belowSubview: errorView)
        lynxView = createdView
        ShellMessageHub.register(
            info: LynxRouterPageInfo(
                pageId: navigationEntryID,
                containerId: navigationEntryID,
                pageKey: request.resolvedRouteKey,
                hostMode: "uikit_view_controller"
            ),
            view: createdView
        )

        LynxNativeRuntime.load(
            url: request.bundleURL,
            initData: request.initialData,
            in: createdView
        )
    }

    /** Provider/首屏错误时，OTA 页面只允许一次 previous/embedded 回滚。 */
    private func handleTemplateLoadFailure(generation: UUID, message: String) {
        guard generation == loadGeneration else { return }
        if let telemetryRenderAttemptId {
            telemetryCoordinator.markPageFailed(
                pageViewId: navigationEntryID,
                renderAttemptId: telemetryRenderAttemptId,
                generation: telemetryGeneration,
                stage: telemetryHandle?.resolvedBundle == nil ? "prepare" : "render",
                reasonCode: message
            )
        }
        if request.isOtaRequest, !firstScreenReady, attemptOtaRecovery(generation: generation, reason: message) {
            return
        }
        loadingView.hide()
        errorView.show(message: message)
        markFirstScreenFailed()
    }

    private func attemptOtaRecovery(generation: UUID, reason: String) -> Bool {
        if otaRecoveryInFlight { return true }
        guard !otaRecoveryUsed,
              let appId = request.lynxAppId,
              let runtime = LynxShell.otaRuntime() else {
            return false
        }
        otaRecoveryUsed = true
        otaRecoveryInFlight = true
        loadingView.show(message: "页面加载失败，正在回滚…", canCancel: false)
        otaPrepareTask?.cancel()
        otaPrepareTask = Task { [weak self] in
            do {
                let rolledBack = try await runtime.rollback(lynxAppId: appId, reason: reason)
                await MainActor.run { [weak self] in
                    guard let self, generation == self.loadGeneration else { return }
                    self.otaPrepareTask = nil
                    self.otaRecoveryInFlight = false
                    if rolledBack {
                        self.rebuildLynxView(resetOtaRecovery: false)
                    } else {
                        self.loadingView.hide()
                        self.errorView.show(message: "\(reason)；OTA 没有可回滚版本")
                        self.markFirstScreenFailed()
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, generation == self.loadGeneration else { return }
                    self.otaPrepareTask = nil
                    self.otaRecoveryInFlight = false
                    self.loadingView.hide()
                    self.errorView.show(message: "\(reason)；回滚失败：\(error.localizedDescription)")
                    self.markFirstScreenFailed()
                }
            }
        }
        return true
    }

    private func didFailBeforeFirstScreen(generation: UUID, view: LynxView, error: Error) {
        guard generation == loadGeneration, view === lynxView, !firstScreenReady else { return }
        handleTemplateLoadFailure(generation: generation, message: error.localizedDescription)
    }

    private func cancelOtaPreparation() {
        otaPrepareTask?.cancel()
        otaPrepareTask = nil
        loadingView.hide()
        if navigationController?.topViewController === self,
           navigationController?.viewControllers.first !== self {
            navigationController?.popViewController(animated: true)
        } else {
            errorView.show(message: "OTA 页面准备已取消")
            markFirstScreenFailed()
        }
    }

    private func didReachFirstScreen(generation: UUID, view: LynxView) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let view else { return }
                self?.didReachFirstScreen(generation: generation, view: view)
            }
            return
        }
        guard generation == loadGeneration, view === lynxView else { return }
        self.view.setNeedsLayout()
        self.view.layoutIfNeeded()
        // 再等一个主线程 tick，确保目标元素的最终 native frame 已经提交。
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view,
                  generation == self.loadGeneration,
                  view === self.lynxView else {
                return
            }
            self.firstScreenReady = true
            self.firstScreenFailed = false
            if let telemetryRenderAttemptId {
                self.telemetryCoordinator.markRuntimeReady(
                    pageViewId: self.navigationEntryID,
                    renderAttemptId: telemetryRenderAttemptId,
                    generation: self.telemetryGeneration
                )
                self.telemetryCoordinator.markFirstScreen(
                    pageViewId: self.navigationEntryID,
                    renderAttemptId: telemetryRenderAttemptId,
                    generation: self.telemetryGeneration
                )
            }
            self.loadingView.hide()
            self.finishReadiness(success: true, reason: nil)
            if let appId = self.request.lynxAppId,
               let bundleName = self.request.bundleName,
               let runtime = LynxShell.otaRuntime() {
                Task { await runtime.reportPageOpen(lynxAppId: appId, bundleName: bundleName) }
            }
        }
    }

    private func markFirstScreenFailed() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.markFirstScreenFailed() }
            return
        }
        firstScreenFailed = true
        if let telemetryRenderAttemptId {
            telemetryCoordinator.markPageFailed(
                pageViewId: navigationEntryID,
                renderAttemptId: telemetryRenderAttemptId,
                generation: telemetryGeneration,
                stage: "render",
                reasonCode: "first_screen_failed"
            )
        }
        finishReadiness(success: false, reason: "target_not_ready")
    }

    /** 向页面发送跨端统一生命周期事件；事件身份由宿主字段决定，业务参数不可覆盖。 */
    private func sendLifecycle(state: String, reason: String) {
        ShellMessageHub.sendLifecycle(
            pageId: navigationEntryID,
            state: state,
            reason: reason
        )
    }

    private func finishReadiness(success: Bool, reason: String?) {
        guard !readinessWaiters.isEmpty else { return }
        let callbacks = Array(readinessWaiters.values)
        readinessWaiters.removeAll()
        callbacks.forEach { $0(success, reason) }
    }

    private func resolvedSize() -> CGSize {
        let scale = UIScreen.main.scale
        let width = request.widthInPhysicalPixels.map { $0 / scale }
            ?? contentHostView.bounds.width
        let height = request.heightInPhysicalPixels.map { $0 / scale }
            ?? contentHostView.bounds.height
        return CGSize(width: max(width, 1), height: max(height, 1))
    }

    /** maintainState=false 离场后释放运行时内容，VC/路由元数据仍留在原生栈中。 */
    private func suspendLynxContent() {
        finishReadiness(success: false, reason: "page_suspended")
        templateProvider?.cancel()
        templateProvider = nil
        firstScreenObserver = nil
        firstScreenReady = false
        firstScreenFailed = false
        ShellMessageHub.unregister(pageId: navigationEntryID)
        lynxView?.removeFromSuperview()
        lynxView = nil
    }

    /**
     * 七种 preset 的稳定容器几何。
     *
     * UINavigationController 栈中仍是全屏 VC；只有 Lynx 内容宿主被塑造成卡片/半屏，
     * 因此不会破坏高级 popTo/closeAll 语义，也不会在动画结束后恢复为系统全屏形态。
     */
    private func layoutPresetContainer() {
        guard isViewLoaded else { return }
        let bounds = view.bounds
        barrierControl.frame = bounds

        let routeType = request.transitionSpec.routeType
        let options = request.transitionSpec.routeOptions
        let frame: CGRect
        let radius: CGFloat
        switch routeType {
        case .bottomSheet:
            let height = max(1, bounds.height * options.heightVH / 100)
            frame = CGRect(
                x: 0,
                y: bounds.maxY - height,
                width: bounds.width,
                height: height
            )
            radius = options.round ? 20 : 0

        case .cupertinoModal, .cupertinoModalInside:
            frame = bounds.inset(
                by: UIEdgeInsets(top: 44, left: 12, bottom: 12, right: 12)
            )
            radius = 18

        case .modalNavigation:
            let width = min(bounds.width * 0.92, 640)
            let height = min(bounds.height * 0.82, 760)
            frame = CGRect(
                x: bounds.midX - width / 2,
                y: bounds.midY - height / 2,
                width: width,
                height: height
            )
            radius = 18

        case .modal:
            let width = min(bounds.width * 0.86, 560)
            let height = min(bounds.height * 0.62, 620)
            frame = CGRect(
                x: bounds.midX - width / 2,
                y: bounds.midY - height / 2,
                width: width,
                height: height
            )
            radius = 18

        case .upwards, .zoom, .none:
            frame = bounds
            radius = 0
        }

        if contentHostView.frame != frame {
            contentHostView.frame = frame
        }
        contentHostView.layer.cornerRadius = radius
        contentHostView.layer.cornerCurve = .continuous
        contentHostView.clipsToBounds = radius > 0
        lynxView?.frame = contentHostView.bounds
        errorView.frame = contentHostView.bounds
    }

    @objc private func didTapBarrier() {
        guard request.transitionSpec.routeType?.isPartialContainer == true,
              request.transitionSpec.routeConfig.barrierDismissible ?? true else {
            return
        }
        _ = ShellNavigator.shared.close()
    }
}
