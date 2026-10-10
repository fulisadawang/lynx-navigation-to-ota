import Foundation
import Lynx
import UIKit

/** CocoaPods Module 对业务 App 暴露的稳定结果类型。 */
public struct LynxShellResult {
    public let code: Int
    public let message: String
    public let affectedCount: Int
    public let data: [String: Any]

    public var isSuccess: Bool { code == 0 }

    init(_ result: LynxNavigationResult) {
        code = result.code
        message = result.message
        affectedCount = result.affectedCount
        data = result.data
    }
}

/**
 * iOS Lynx 壳对宿主公开的唯一高层 Interface。
 *
 * Runtime、UIViewController、Provider、手写 NativeModules、导航栈和转场都留在
 * LynxShellKit Implementation 内。业务项目只需显式 `import LynxShellKit`，不需要
 * Sparkling autolink，也不需要复制任何壳源码。
 */
public enum LynxShell {
    public typealias AppHomeHandler = (
        _ navigationController: UINavigationController,
        _ options: [String: Any]
    ) -> Bool

    private static let otaRuntimeLock = NSLock()
    private static var installedOtaRuntime: LynxBundleRuntime?
    private static let backGestureModeLock = NSLock()
    private static var hostManagedBackGesture = false

    /** 必须在创建第一个 LynxView 前调用；内部使用 dispatch_once，重复调用安全。 */
    public static func bootstrap() {
        LynxNativeRuntime.bootstrap()
        ShellLocaleStore.startObserving { state in
            _ = ShellMessageHub.updateLocale(state)
        }
    }

    /** 绑定业务 App 实际承载 Lynx 页面的 UINavigationController。 */
    public static func attach(to navigationController: UINavigationController) {
        ShellNavigator.shared.attach(navigationController)
    }

    /** 安装 Router 内置 OTA runtime；传 nil 会关闭 appId + bundleName 页面。 */
    static func installOtaRuntime(_ runtime: LynxBundleRuntime?) {
        otaRuntimeLock.lock()
        installedOtaRuntime = runtime
        otaRuntimeLock.unlock()
    }

    /** 页面容器只读取当前安装实例，不接触 OTA 的磁盘目录或网络实现。 */
    static func otaRuntime() -> LynxBundleRuntime? {
        otaRuntimeLock.lock()
        defer { otaRuntimeLock.unlock() }
        return installedOtaRuntime
    }

    /** Sample/宿主可选择完全接管 UINavigationController 的全局返回手势。 */
    static func setHostManagedBackGesture(_ enabled: Bool) {
        backGestureModeLock.lock()
        hostManagedBackGesture = enabled
        backGestureModeLock.unlock()
    }

    static func hostManagesBackGesture() -> Bool {
        backGestureModeLock.lock()
        defer { backGestureModeLock.unlock() }
        return hostManagedBackGesture
    }

    /** 注入“回到业务主 Tab/主页”的实现；后续注入会替换旧 Handler。 */
    public static func installAppHomeHandler(_ handler: @escaping AppHomeHandler) {
        ShellNavigator.shared.installAppHomeHandler(handler)
    }

    /**
     * 推荐给其他项目的字符串入口，与页面侧 NativeModules.open 共用协议。
     *
     * route 支持 assets、https、lynxshell、hybrid 与 Explorer local；
     * optionsJSON 同时承载页面参数、launchMode 和 transition。
     */
    @discardableResult
    public static func open(
        _ route: String,
        optionsJSON: String = "{}"
    ) throws -> LynxShellResult {
        let request = try LynxRouteParser.request(from: route, optionsJSON: optionsJSON)
        let options = try ShellNavigationOptions.fromJSON(optionsJSON)
        return LynxShellResult(ShellNavigator.shared.open(request, options: options))
    }

    /** 原生调试表单使用的强类型便捷入口。 */
    @discardableResult
    public static func open(
        bundleURL: String,
        title: String,
        initialDataJSON: String = "{}",
        globalPropsJSON: String = "{}",
        fullscreen: Bool = true,
        allowHTTPInDebug: Bool = false
    ) throws -> LynxShellResult {
        let request = try LynxRouteParser.request(
            bundleURL: bundleURL,
            title: title,
            initialDataJSON: initialDataJSON,
            globalPropsJSON: globalPropsJSON,
            fullscreen: fullscreen,
            allowHTTPInDebug: allowHTTPInDebug
        )
        return LynxShellResult(ShellNavigator.shared.open(request))
    }

    /** 恢复上次可序列化的 Lynx session；快照失效时返回 false 并自动清理。 */
    @discardableResult
    public static func restoreNavigationStackIfPossible() -> Bool {
        ShellNavigator.shared.restoreNavigationStackIfPossible()
    }

    /** Scene 进入后台时取消交互转场并同步导航快照。 */
    public static func sceneDidEnterBackground() {
        ShellNavigator.shared.cancelActiveTransitionForBackground()
        DispatchQueue.main.async {
            ShellNavigator.shared.navigationStackDidChange()
        }
    }
}

/** 一个原生 Tab 的逻辑描述；不包含 UITabBarItem 或其它宿主导航 UI。 */
public struct LynxTabSpec {
    public let tabId: String
    public let bundleURL: String
    public let title: String
    public let routeKey: String
    public let initialData: [String: Any]
    public let globalProps: [String: Any]
    public let lynxAppId: String?
    public let bundleName: String?
    public let backgroundColor: String

    public init(
        tabId: String,
        bundleURL: String,
        title: String = "",
        routeKey: String = "",
        initialData: [String: Any] = [:],
        globalProps: [String: Any] = [:],
        lynxAppId: String? = nil,
        bundleName: String? = nil,
        backgroundColor: String = "#FFFFFF"
    ) {
        self.tabId = tabId
        self.bundleURL = bundleURL
        self.title = title.isEmpty ? tabId : title
        self.routeKey = routeKey.isEmpty ? tabId : routeKey
        self.initialData = initialData
        self.globalProps = globalProps
        self.lynxAppId = lynxAppId
        self.bundleName = bundleName
        self.backgroundColor = backgroundColor
    }
}

/**
 * 不包含 TabBar 的 Lynx 内容容器。
 *
 * 宿主可以把它放进 UITabBarController 或普通 UIViewController；它只负责一个 LynxView、
 * 已同步 current 的 cache-only 读取和生命周期，不负责 Tab 选中态或底部导航。
 */
public final class LynxTabViewController: UIViewController, ShellSystemUIOwner {
    public let spec: LynxTabSpec
    private let contentView = UIView()
    private var lynxView: LynxView?
    private var templateProvider: ShellTemplateProvider?
    private var releaseLease: OtaBundleLease?
    private var preparedResources: OtaPreparedResources?
    private var resourceFetcher: LynxLocalResourceFetcher?
    /** 当前 LynxView 对应的请求；语言/布局原位更新需要复用同一份页面身份。 */
    private var currentRequest: LynxPageRequest?
    /** 当前 LynxView 的完整 GlobalProps；主题更新不能只回传一个 theme 字段。 */
    private var runtimeGlobalProps: [String: Any]?
    private let layoutUpdateCoordinator = ShellLayoutUpdateCoordinator()
    private var latestLayoutSnapshot: ShellLayoutSnapshot?
    private var loadTask: Task<Void, Never>?
    private let pageID: String
    private var didStartLoad = false
    private var loadGeneration = LynxTabLoadGeneration()
    private var userContextObserver: NSObjectProtocol?
    private var userSyncObserver: NSObjectProtocol?
    private var firstScreenObserver: LynxFirstScreenObserver?
    private var monitorScope: LynxMonitorScope?
    private var monitorObserver: LynxMonitorObserver?
    private var monitorVisibility: LynxMonitorVisibility = .hidden
    let lynxSystemUIState = ShellSystemUIState()
    var lynxSystemUIView: LynxView? { lynxView }
    private var firstScreenReached = false
    private var otaHealthGate = LynxOtaHealthGate()
    private var otaHealthCompletion: ((NSDictionary) -> Void)?
    private var otaHealthTask: Task<Void, Never>?
    private var currentBundleMetadata: [String: Any]?
    private var otaRecoveryUsed = false
    private var recoveringStable = false
#if DEBUG
    private var debugLoadCount = 0
    private var debugResolveCurrentCount = 0
    private var debugRenderCount = 0
    private var debugInstanceID = "none"
    private var debugLastError = "idle"
    private var debugBundleIdentity = "release=none;source=none"

    /** 仅供 Debug UI Test 读取，不进入 Release API。 */
    public var debugState: String {
        "instance=\(debugInstanceID);load=\(debugLoadCount);resolve=\(debugResolveCurrentCount);render=\(debugRenderCount);error=\(debugLastError);\(debugBundleIdentity)"
    }
#endif

    public override var prefersStatusBarHidden: Bool { lynxSystemUIState.statusBarHidden ?? false }
    public override var preferredStatusBarStyle: UIStatusBarStyle { lynxSystemUIState.statusBarStyle ?? super.preferredStatusBarStyle }
    public override var prefersHomeIndicatorAutoHidden: Bool { lynxSystemUIState.homeIndicatorHidden ?? false }
    public override var supportedInterfaceOrientations: UIInterfaceOrientationMask { lynxSystemUIState.orientationMask ?? super.supportedInterfaceOrientations }

    public init(spec: LynxTabSpec) {
        self.spec = spec
        self.pageID = "lynx-tab-\(spec.tabId)-\(UUID().uuidString)"
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("LynxTabViewController 只允许通过 LynxTabSpec 初始化")
    }

    deinit {
        otaHealthTask?.cancel()
        otaHealthCompletion?(["code": 1002, "message": "Tab已销毁"])
#if DEBUG
        LynxDebugBridge.detach(view: lynxView)
#endif
        monitorScope?.close(reason: "tab_destroyed")
        LynxMonitorViewBinding.unbind(lynxView)
        if let userContextObserver { NotificationCenter.default.removeObserver(userContextObserver) }
        if let userSyncObserver { NotificationCenter.default.removeObserver(userSyncObserver) }
        loadTask?.cancel()
        ShellMessageHub.unregister(pageId: pageID)
        templateProvider?.cancel()
        if let lynxView { LynxNativeRuntime.destroy(view: lynxView) }
        lynxView = nil
        releaseCurrentLease()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(shellHex: spec.backgroundColor) ?? .systemBackground
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.backgroundColor = view.backgroundColor
        view.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: view.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        if spec.lynxAppId != nil {
            userContextObserver = NotificationCenter.default.addObserver(forName: .lynxOtaUserContextDidChange, object: nil, queue: .main) { [weak self] _ in
                self?.refreshFromCurrent()
            }
            userSyncObserver = NotificationCenter.default.addObserver(forName: .lynxOtaUserSyncCompleted, object: nil, queue: .main) { [weak self] notification in
                // 全量可能部分成功：只从已提交 State 重读，不能因另一个 App 失败漏掉撤销/更新。
                guard let epoch = notification.userInfo?["epoch"] as? UInt64,
                      epoch == LynxRouter.otaUserIdentityEpoch else { return }
                self?.refreshFromCurrent()
            }
        }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !didStartLoad,
           contentView.bounds.width > 0,
           contentView.bounds.height > 0 {
            didStartLoad = true
            load()
        }
        if lynxView != nil {
            scheduleLayoutUpdate()
        }
    }

    public override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        scheduleLayoutUpdate()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 常驻 Tab 在未选中时可能没有进入当前 trait 传播链；切回可见前重新对齐，
        // 不重建 LynxView、Bundle 或 OTA lease。
        synchronizeColorScheme()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        monitorVisibility = .visible
        monitorScope?.setVisibility(.visible)
#if DEBUG
        LynxDebugBridge.updateVisibility(view: lynxView, visibility: "visible")
#endif
        lynxView?.onEnterForeground()
        // 首次布局后再补一次完整 GlobalProps；创建前的注入用于初始引擎配置，
        // 这里确保 Lynx 页面 JS 已经能读到 theme 和 native_tab_id。
        synchronizeColorScheme()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        monitorVisibility = .hidden
        monitorScope?.setVisibility(.hidden)
#if DEBUG
        LynxDebugBridge.updateVisibility(view: lynxView, visibility: "hidden")
#endif
        lynxView?.onEnterBackground()
        super.viewWillDisappear(animated)
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection == nil ||
                previousTraitCollection!.hasDifferentColorAppearance(comparedTo: traitCollection) else {
            return
        }
        synchronizeColorScheme()
    }

    /** 用户主动刷新可试本地 candidate；普通切换复用实例，不触发 Tab 网络请求。 */
    public func refreshFromCurrent() {
        reloadContent(recovering: false)
    }

    private func reloadContent(recovering: Bool) {
        cancelOtaHealth()
        otaHealthGate = LynxOtaHealthGate()
        currentBundleMetadata = nil
        recoveringStable = recovering
        if !recovering { otaRecoveryUsed = false }
        closeMonitoring(reason: "tab_refreshed")
        loadTask?.cancel()
        loadTask = nil
        layoutUpdateCoordinator.invalidate()
        latestLayoutSnapshot = nil
        loadGeneration.invalidate()
        templateProvider?.cancel()
        templateProvider = nil
        firstScreenObserver = nil
        firstScreenReached = false
#if DEBUG
        debugBundleIdentity = "release=none;source=none"
#endif
        ShellMessageHub.unregister(pageId: pageID)
        if let lynxView { LynxNativeRuntime.destroy(view: lynxView) }
        lynxView?.removeFromSuperview()
        lynxView = nil
        currentRequest = nil
        runtimeGlobalProps = nil
        releaseCurrentLease()
        contentView.viewWithTag(0x4C5958)?.removeFromSuperview()
        didStartLoad = false
        if isViewLoaded,
           contentView.bounds.width > 0,
           contentView.bounds.height > 0 {
            didStartLoad = true
            load(monitorLoadKind: .reload)
        } else {
            view.setNeedsLayout()
        }
    }

    private func load(monitorLoadKind: LynxMonitorLoadKind = .initial) {
        let generation = loadGeneration.begin()
        monitorScope = LynxMonitor.beginView(kind: .tab, loadKind: monitorLoadKind, visibility: monitorVisibility)
        let isOta = spec.lynxAppId?.isEmpty == false && spec.bundleName?.isEmpty == false
        let bundleRuntime = isOta ? LynxShell.otaRuntime() : nil
        monitorScope?.setRequest(source: isOta ? .ota : (RemoteBundlePolicy.isRemote(spec.bundleURL) ? .directHTTPS : .directAsset),
                                 appId: isOta ? spec.lynxAppId : nil, bundleName: isOta ? spec.bundleName : nil,
                                 otaScope: bundleRuntime?.monitoringScope)
#if DEBUG
        debugLoadCount += 1
        debugLastError = "loading"
#endif
        guard let appId = spec.lynxAppId,
              let bundleName = spec.bundleName,
              !appId.isEmpty,
              !bundleName.isEmpty else {
            render(prefetchedData: nil, generation: generation)
            return
        }
        guard let runtime = bundleRuntime else {
            showError("Tab \(spec.tabId) 没有安装 OTA runtime；Tab 加载不会联网")
            return
        }
#if DEBUG
        debugResolveCurrentCount += 1
        let resolveOrdinal = debugResolveCurrentCount
#endif
        loadTask = Task { [weak self] in
            var pendingLease: OtaBundleLease?
            var pendingResources: OtaPreparedResources?
            defer {
                if let pendingResources {
                    pendingResources.close(releasing: pendingLease)
                } else if let pendingLease {
                    Task { await pendingLease.close() }
                }
            }
            do {
#if DEBUG
                if resolveOrdinal == 1,
                   let rawDelay = ProcessInfo.processInfo.environment[
                       "LYNX_TEST_TAB_DEFER_FIRST_RESOLVE_MS"
                   ],
                   let delayMilliseconds = UInt64(rawDelay),
                   delayMilliseconds > 0 {
                    // 故意忽略取消结果，让旧 resolve 迟到；最终由 generation 门禁丢弃。
                    try? await Task.sleep(nanoseconds: delayMilliseconds * 1_000_000)
                }
#endif
                // 初次/主动刷新可试本地候选；普通 Tab 切换仍复用实例，不触发网络。
                let resolved = self?.recoveringStable == true
                    ? try await runtime.resolveCurrent(lynxAppId: appId, bundleName: bundleName)
                    : try await runtime.resolvePage(lynxAppId: appId, bundleName: bundleName)
                guard let prepared = resolved else {
                    throw NSError(
                        domain: "LynxTabViewController",
                        code: 404,
                        userInfo: [NSLocalizedDescriptionKey: "Tab \(self?.spec.tabId ?? bundleName) 没有 active Bundle"]
                    )
                }
                pendingLease = prepared.releaseLease
                let resources = try await runtime.prepareResources(for: prepared)
                pendingResources = resources
                let data = try Data(contentsOf: prepared.fileURL, options: .mappedIfSafe)
                var metadata: [String: Any] = [
                    "lynxAppId": prepared.lynxAppId,
                    "releaseId": prepared.releaseId ?? "unknown",
                    // cache-only 是加载策略；Bundle 的真实来源仍由 Runtime 返回，
                    // 这样 Tab 与单独打开页面展示同一个 current/baseline 身份。
                    "source": prepared.source,
                    "loadPolicy": "cache_only",
                    "bundleName": prepared.bundleName
                ]
                metadata["_identityEpoch"] = prepared.userIdentityEpoch
                metadata["selectionKind"] = prepared.selectionKind
                metadata["releaseSequence"] = prepared.releaseSequence
                let accepted: Bool = await MainActor.run { [weak self] in
                    guard let self, self.loadGeneration.accepts(generation) else { return false }
                    if let epoch = prepared.userIdentityEpoch, epoch != LynxRouter.otaUserIdentityEpoch { return false }
                    self.monitorScope?.setPreparedBundle(prepared)
#if DEBUG
                    self.debugBundleIdentity = "release=\(prepared.releaseId ?? "none");source=\(prepared.source);kind=\(prepared.selectionKind ?? "embedded");sequence=\(prepared.releaseSequence ?? "none")"
#endif
                    self.render(
                        prefetchedData: data,
                        bundleMetadata: metadata,
                        releaseLease: prepared.releaseLease,
                        preparedResources: resources,
                        generation: generation
                    )
                    return true
                }
                if accepted { pendingLease = nil; pendingResources = nil }
            } catch is CancellationError {
                return
            } catch {
#if DEBUG
                self?.debugLastError = error.localizedDescription
#endif
                await MainActor.run { [weak self] in
                    guard let self, self.loadGeneration.accepts(generation) else { return }
                    self.handleTabFailure(generation: generation, message: "Tab 加载失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func render(
        prefetchedData: Data?,
        bundleMetadata: [String: Any]? = nil,
        releaseLease: OtaBundleLease? = nil,
        preparedResources: OtaPreparedResources? = nil,
        generation: UUID
    ) {
        currentBundleMetadata = bundleMetadata
        guard lynxView == nil else {
            if let preparedResources {
                preparedResources.close(releasing: releaseLease)
            } else if let releaseLease {
                Task { await releaseLease.close() }
            }
            return
        }
        releaseCurrentLease()
        self.releaseLease = releaseLease
        self.preparedResources = preparedResources
        do {
            let request = try LynxPageRequest(
                bundleURL: spec.bundleURL,
                lynxAppId: spec.lynxAppId,
                bundleName: spec.bundleName,
                routeKey: spec.routeKey,
                title: spec.title,
                initialData: spec.initialData,
                globalProps: spec.globalProps,
                fullscreen: true,
                showNavigationBar: false,
                hideStatusBar: false,
                // Tab 页面仍允许宿主导航栈侧滑返回；TabBar 自身没有上一页时
                // interactivePop 会由 UIKit 按栈深度自然忽略。
                backGestureEnabled: true,
                allowHTTPInDebug: false,
                orientation: .system,
                backgroundColor: spec.backgroundColor,
                widthInPhysicalPixels: nil,
                heightInPhysicalPixels: nil
            ).validated()
            currentRequest = request
            let monitoredScope = monitorScope
            let monitoredURL = request.bundleURL
            let provider = ShellTemplateProvider(
                allowHTTPInDebug: false,
                onLoadError: { [weak self] _, error in
                    DispatchQueue.main.async {
                        guard let self, self.loadGeneration.accepts(generation) else { return }
                        self.showError("Tab 加载失败：\(error.localizedDescription)")
                    }
                },
                prefetchedURL: request.bundleURL,
                prefetchedData: prefetchedData,
                onTemplateData: monitoredScope.map { scope in
                    { url, data in if url == monitoredURL { scope.resolved(data) } }
                }
            )
            templateProvider = provider
            let localFetcher = preparedResources?.makeFetcher(provider: provider)
            resourceFetcher = localFetcher
            var props = ShellGlobalPropsFactory.make(
                for: contentView,
                request: request,
                pageId: pageID,
                sessionId: "native-tab-host",
                bundleMetadata: bundleMetadata,
                layoutSnapshot: latestLayoutSnapshot
            )
            props["__lynxRouterNavigationModel"] = "native_tab_host"
            props["__lynxRouterPlatformContainer"] = "uikit_tab_container"
            runtimeGlobalProps = props
            let createStarted = ProcessInfo.processInfo.systemUptime
            let created = LynxNativeRuntime.makeView(
                provider: provider,
                resourceFetcher: localFetcher,
                screenSize: latestLayoutSnapshot?.screenSize
                    ?? ShellLayoutSnapshot.measure(for: contentView).screenSize,
                viewportSize: latestLayoutSnapshot?.viewportSize
                    ?? contentView.bounds.size,
                globalProps: props
            )
            if let monitoredScope {
                LynxMonitorViewBinding.bind(monitoredScope, to: created)
                let monitor = LynxMonitorObserver(scope: monitoredScope)
                monitorObserver = monitor
                created.addLifecycleClient(monitor)
                monitoredScope.didCreate(durationMs: (ProcessInfo.processInfo.systemUptime - createStarted) * 1000)
            }
            let errorMonitor = monitorObserver
            let observer = LynxFirstScreenObserver(
                generation: generation,
                onFirstScreen: { [weak self] observedGeneration, view in
                    DispatchQueue.main.async { [weak self, weak view] in
                        guard let self, let view, self.loadGeneration.accepts(observedGeneration), view === self.lynxView else { return }
                        guard !self.otaHealthGate.failed else { return }
                        self.firstScreenReached = true
                        self.otaHealthGate.markFirstScreen()
                        self.confirmOtaHealthIfReady(generation: observedGeneration)
#if DEBUG
                        self.debugLastError = "ready"
#endif
                    }
                },
                onFirstScreenError: { [weak self] observedGeneration, _, error in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.loadGeneration.accepts(observedGeneration) else { return }
                        self.handleTabFailure(generation: observedGeneration, message: "Tab运行失败：\(error.localizedDescription)")
                    }
                },
                onErrorObserved: errorMonitor.map { monitor in { error in monitor.receivedError(error) } }
            )
            firstScreenObserver = observer
            created.addLifecycleClient(observer)
#if DEBUG
            debugRenderCount += 1
            debugInstanceID = String(UUID().uuidString.prefix(8))
            debugLastError = "rendered"
#endif
            created.backgroundColor = contentView.backgroundColor
            created.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(created)
            NSLayoutConstraint.activate([
                created.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                created.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                created.topAnchor.constraint(equalTo: contentView.topAnchor),
                created.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
            lynxView = created
#if DEBUG
            LynxDebugBridge.attach(
                view: created,
                viewId: monitorScope?.viewId,
                containerKind: "tab",
                pageId: pageID,
                routeKey: request.resolvedRouteKey,
                title: request.title,
                bundleURL: request.bundleURL,
                bundleMetadata: bundleMetadata,
                globalProps: props,
                visibility: monitorVisibility == .visible ? "visible" : "hidden"
            )
#endif
            ShellMessageHub.register(
                info: LynxRouterPageInfo(
                    pageId: pageID,
                    containerId: pageID,
                    pageKey: request.resolvedRouteKey,
                    hostMode: "uikit_tab_container"
                ),
                view: created,
                updateLocale: { [weak self] state in
                    self?.synchronizeLocale(state)
                },
                markOtaHealthy: { [weak self, weak created] completion in
                    guard let self, let created else {
                        completion(["code": 1002, "message": "调用Tab已销毁"])
                        return
                    }
                    self.markOtaHealthy(generation: generation, view: created, completion: completion)
                }
            )
            LynxNativeRuntime.load(url: request.bundleURL, initData: request.initialData, in: created)
        } catch {
            showError("Tab 容器创建失败：\(error.localizedDescription)")
        }
    }

    private func markOtaHealthy(generation: UUID, view: LynxView, completion: @escaping (NSDictionary) -> Void) {
        guard loadGeneration.accepts(generation), view === lynxView, !otaHealthGate.failed else {
            completion(["code": 1002, "message": "Tab代次已失效"])
            return
        }
        guard currentBundleMetadata?["source"] as? String == "candidate_trial" else {
            completion(["code": 0, "message": "", "data": ["confirmed": otaHealthGate.confirmed, "reason": "not_candidate"]])
            return
        }
        guard otaHealthCompletion == nil else {
            completion(["code": 1006, "message": "健康确认正在等待首屏或提交"])
            return
        }
        otaHealthCompletion = completion
        otaHealthGate.markBusinessHealth()
        confirmOtaHealthIfReady(generation: generation)
    }

    private func confirmOtaHealthIfReady(generation: UUID) {
        guard loadGeneration.accepts(generation),
              currentBundleMetadata?["source"] as? String == "candidate_trial",
              let appId = spec.lynxAppId, let runtime = LynxShell.otaRuntime(),
              otaHealthGate.beginConfirmation() else { return }
        let releaseId = currentBundleMetadata?["releaseId"] as? String
        let epoch = currentBundleMetadata?["_identityEpoch"] as? UInt64
        otaHealthTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let confirmed = try await runtime.confirmCandidateHealthy(lynxAppId: appId,
                    expectedReleaseId: releaseId, expectedIdentityEpoch: epoch)
                await MainActor.run {
                    guard let self, self.loadGeneration.accepts(generation) else { return }
                    guard confirmed, epoch == nil || epoch == LynxRouter.otaUserIdentityEpoch,
                          self.otaHealthGate.completeConfirmation() else {
                        self.cancelOtaHealth()
                        return
                    }
                    self.otaHealthTask = nil
                    self.currentBundleMetadata?["source"] = "ota_current"
                    let callback = self.otaHealthCompletion
                    self.otaHealthCompletion = nil
                    callback?(["code": 0, "message": "", "data": ["confirmed": true, "releaseId": releaseId ?? ""]])
#if DEBUG
                    self.debugBundleIdentity = "release=\(releaseId ?? "unknown");source=ota_current"
#endif
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.loadGeneration.accepts(generation) else { return }
                    let callback = self.otaHealthCompletion
                    self.otaHealthCompletion = nil
                    self.otaHealthTask = nil
                    callback?(["code": 1003, "message": error.localizedDescription])
                    self.handleTabFailure(generation: generation, message: "OTA健康确认失败")
                }
            }
        }
    }

    private func cancelOtaHealth() {
        otaHealthTask?.cancel()
        otaHealthTask = nil
        let callback = otaHealthCompletion
        otaHealthCompletion = nil
        callback?(["code": 1002, "message": "Tab已销毁或换包"])
    }

    private func handleTabFailure(generation: UUID, message: String) {
        guard loadGeneration.accepts(generation) else { return }
        let mayRecover = !firstScreenReached || (currentBundleMetadata?["source"] as? String == "candidate_trial" && !otaHealthGate.confirmed)
        let releaseId = currentBundleMetadata?["releaseId"] as? String
        let epoch = currentBundleMetadata?["_identityEpoch"] as? UInt64
        let failedCandidate = currentBundleMetadata?["source"] as? String == "candidate_trial"
        showError(message)
        guard mayRecover, !otaRecoveryUsed, let appId = spec.lynxAppId,
              let runtime = LynxShell.otaRuntime() else { return }
        otaRecoveryUsed = true
        loadTask = Task { [weak self] in
            do {
                let recovered = failedCandidate
                    ? try await runtime.recoverFailedCandidate(lynxAppId: appId, expectedReleaseId: releaseId, expectedIdentityEpoch: epoch)
                    : try await runtime.rollback(lynxAppId: appId, reason: message,
                        expectedReleaseId: releaseId, expectedIdentityEpoch: epoch)
                await MainActor.run {
                    guard let self, self.loadGeneration.accepts(generation), recovered else { return }
                    self.reloadContent(recovering: true)
                }
            } catch {
                await MainActor.run {
                    guard let self, self.loadGeneration.accepts(generation) else { return }
                    self.showError("\(message)；恢复失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func showError(_ message: String) {
        guard isViewLoaded else { return }
        otaHealthGate.fail()
        cancelOtaHealth()
        ShellMessageHub.unregister(pageId: pageID)
        monitorScope?.failed(reason: "tab_template_or_first_screen_failure")
        closeMonitoring(reason: "tab_content_released")
        templateProvider?.cancel()
        templateProvider = nil
        firstScreenObserver = nil
        if let lynxView { LynxNativeRuntime.destroy(view: lynxView) }
        lynxView?.removeFromSuperview()
        lynxView = nil
        runtimeGlobalProps = nil
        releaseCurrentLease()
#if DEBUG
        debugLastError = message
#endif
        let label = contentView.viewWithTag(0x4C5958) as? UILabel ?? UILabel()
        label.tag = 0x4C5958
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = message
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        if label.superview == nil {
            contentView.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
                label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
                label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            ])
        }
    }

    private func closeMonitoring(reason: String) {
#if DEBUG
        LynxDebugBridge.detach(view: lynxView)
#endif
        monitorScope?.close(reason: reason)
        LynxMonitorViewBinding.unbind(lynxView)
        if let monitorObserver { lynxView?.removeLifecycleClient(monitorObserver) }
        monitorObserver = nil
        monitorScope = nil
    }

    /**
     * 用当前 Tab 容器的有效 trait 同步主题。宿主自定义 UITabBarController 时可以传入
     * 父容器 trait，确保隐藏的常驻 Tab 也使用同一主题源。
     */
    public func synchronizeColorScheme(with source: UITraitCollection? = nil) {
        guard Thread.isMainThread, isViewLoaded, let lynxView else { return }
        let effectiveTrait = source ?? view.window?.traitCollection ?? traitCollection
        let darkMode = effectiveTrait.userInterfaceStyle == .dark
        LynxNativeRuntime.updateColorScheme(for: lynxView, darkMode: darkMode)
        guard var props = runtimeGlobalProps else { return }
        props["theme"] = darkMode ? "Dark" : "Light"
        runtimeGlobalProps = props
        LynxNativeRuntime.updateGlobalProps(props, in: lynxView)
#if DEBUG
        LynxDebugBridge.updateGlobalProps(view: lynxView, globalProps: props)
#endif
    }

    /** 语言状态由宿主统一提交；Tab 只原位更新完整 GlobalProps，不重新加载 Bundle。 */
    func synchronizeLocale(_ state: LynxLocaleState) {
        guard Thread.isMainThread, isViewLoaded, let lynxView, let request = currentRequest else { return }
        var props = ShellGlobalPropsFactory.make(
            for: contentView,
            request: request,
            pageId: pageID,
            sessionId: "native-tab-host",
            bundleMetadata: runtimeGlobalProps?["__lynxBundleMeta"] as? [String: Any],
            localeState: state,
            layoutSnapshot: latestLayoutSnapshot
        )
        props["__lynxRouterNavigationModel"] = "native_tab_host"
        props["__lynxRouterPlatformContainer"] = "uikit_tab_container"
        runtimeGlobalProps = props
        LynxNativeRuntime.updateGlobalProps(props, in: lynxView)
#if DEBUG
        LynxDebugBridge.updateGlobalProps(view: lynxView, globalProps: props)
#endif
    }

    private func scheduleLayoutUpdate() {
        layoutUpdateCoordinator.schedule(
            for: contentView,
            viewportSize: { [weak self] in self?.contentView.bounds.size ?? .zero },
            onUpdate: { [weak self] snapshot in
                self?.applyLayoutUpdate(snapshot)
            }
        )
    }

    private func applyLayoutUpdate(_ snapshot: ShellLayoutSnapshot) {
        latestLayoutSnapshot = snapshot
        guard let lynxView, let request = currentRequest else { return }
        LynxNativeRuntime.updateLayout(
            view: lynxView,
            size: snapshot.viewportSize,
            screenSize: snapshot.screenSize
        )
        var props = ShellGlobalPropsFactory.make(
            for: contentView,
            request: request,
            pageId: pageID,
            sessionId: "native-tab-host",
            bundleMetadata: runtimeGlobalProps?["__lynxBundleMeta"] as? [String: Any],
            layoutSnapshot: snapshot
        )
        props["__lynxRouterNavigationModel"] = "native_tab_host"
        props["__lynxRouterPlatformContainer"] = "uikit_tab_container"
        runtimeGlobalProps = props
        LynxNativeRuntime.updateGlobalProps(props, in: lynxView)
#if DEBUG
        LynxDebugBridge.updateGlobalProps(view: lynxView, globalProps: props)
#endif
    }

    private func releaseCurrentLease() {
        resourceFetcher?.cancel()
        resourceFetcher = nil
        let resources = preparedResources
        preparedResources = nil
        let lease = releaseLease
        releaseLease = nil
        if let resources {
            resources.close(releasing: lease)
        } else if let lease {
            Task { await lease.close() }
        }
    }
}
