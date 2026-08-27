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
public final class LynxTabViewController: UIViewController {
    public let spec: LynxTabSpec
    private let contentView = UIView()
    private var lynxView: LynxView?
    private var templateProvider: ShellTemplateProvider?
    private var releaseLease: OtaBundleLease?
    private var loadTask: Task<Void, Never>?
    private let pageID: String
    private var didStartLoad = false
    private var loadGeneration = LynxTabLoadGeneration()
#if DEBUG
    private var debugLoadCount = 0
    private var debugResolveCurrentCount = 0
    private var debugRenderCount = 0
    private var debugInstanceID = "none"
    private var debugLastError = "idle"

    /** 仅供 Debug UI Test 读取，不进入 Release API。 */
    public var debugState: String {
        "instance=\(debugInstanceID);load=\(debugLoadCount);resolve=\(debugResolveCurrentCount);render=\(debugRenderCount);error=\(debugLastError)"
    }
#endif

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
        loadTask?.cancel()
        ShellMessageHub.unregister(pageId: pageID)
        templateProvider?.cancel()
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
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !didStartLoad,
           contentView.bounds.width > 0,
           contentView.bounds.height > 0 {
            didStartLoad = true
            load()
        }
        if let lynxView {
            LynxNativeRuntime.updateLayout(view: lynxView, size: contentView.bounds.size)
        }
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        lynxView?.onEnterForeground()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        lynxView?.onEnterBackground()
        super.viewWillDisappear(animated)
    }

    /** 用户主动刷新 OTA 后，销毁当前 LynxView 并重新读取已提交 current；不触发 Tab 网络请求。 */
    public func refreshFromCurrent() {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration.invalidate()
        templateProvider?.cancel()
        templateProvider = nil
        ShellMessageHub.unregister(pageId: pageID)
        lynxView?.removeFromSuperview()
        lynxView = nil
        releaseCurrentLease()
        contentView.viewWithTag(0x4C5958)?.removeFromSuperview()
        didStartLoad = false
        if isViewLoaded,
           contentView.bounds.width > 0,
           contentView.bounds.height > 0 {
            didStartLoad = true
            load()
        } else {
            view.setNeedsLayout()
        }
    }

    private func load() {
        let generation = loadGeneration.begin()
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
        guard let runtime = LynxShell.otaRuntime() else {
            showError("Tab \(spec.tabId) 没有安装 OTA runtime；Tab 加载不会联网")
            return
        }
#if DEBUG
        debugResolveCurrentCount += 1
        let resolveOrdinal = debugResolveCurrentCount
#endif
        loadTask = Task { [weak self] in
            var pendingLease: OtaBundleLease?
            defer {
                if let pendingLease {
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
                // Native Tab 只读取已经提交的 current；缺失时不 repair、不请求网络。
                guard let prepared = try await runtime.resolveCurrent(
                    lynxAppId: appId,
                    bundleName: bundleName
                ) else {
                    throw NSError(
                        domain: "LynxTabViewController",
                        code: 404,
                        userInfo: [NSLocalizedDescriptionKey: "Tab \(self?.spec.tabId ?? bundleName) 没有 active Bundle"]
                    )
                }
                pendingLease = prepared.releaseLease
                let data = try Data(contentsOf: prepared.fileURL, options: .mappedIfSafe)
                let metadata: [String: Any] = [
                    "lynxAppId": prepared.lynxAppId,
                    "releaseId": prepared.releaseId ?? "unknown",
                    // cache-only 是加载策略；Bundle 的真实来源仍由 Runtime 返回，
                    // 这样 Tab 与单独打开页面展示同一个 current/baseline 身份。
                    "source": prepared.source,
                    "loadPolicy": "cache_only",
                    "bundleName": prepared.bundleName
                ]
                let accepted: Bool = await MainActor.run { [weak self] in
                    guard let self, self.loadGeneration.accepts(generation) else { return false }
                    self.render(
                        prefetchedData: data,
                        bundleMetadata: metadata,
                        releaseLease: prepared.releaseLease,
                        generation: generation
                    )
                    return true
                }
                if accepted { pendingLease = nil }
            } catch is CancellationError {
                return
            } catch {
#if DEBUG
                self?.debugLastError = error.localizedDescription
#endif
                await MainActor.run { [weak self] in
                    guard let self, self.loadGeneration.accepts(generation) else { return }
                    self.showError("Tab 加载失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func render(
        prefetchedData: Data?,
        bundleMetadata: [String: Any]? = nil,
        releaseLease: OtaBundleLease? = nil,
        generation: UUID
    ) {
        guard lynxView == nil else {
            if let releaseLease { Task { await releaseLease.close() } }
            return
        }
        releaseCurrentLease()
        self.releaseLease = releaseLease
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
            let provider = ShellTemplateProvider(
                allowHTTPInDebug: false,
                onLoadError: { [weak self] _, error in
                    DispatchQueue.main.async {
                        guard let self, self.loadGeneration.accepts(generation) else { return }
                        self.showError("Tab 加载失败：\(error.localizedDescription)")
                    }
                },
                prefetchedURL: request.bundleURL,
                prefetchedData: prefetchedData
            )
            templateProvider = provider
            var props = ShellGlobalPropsFactory.make(
                for: contentView,
                request: request,
                pageId: pageID,
                sessionId: "native-tab-host",
                bundleMetadata: bundleMetadata
            )
            props["__lynxRouterNavigationModel"] = "native_tab_host"
            props["__lynxRouterPlatformContainer"] = "uikit_tab_container"
            let created = LynxNativeRuntime.makeView(
                provider: provider,
                screenSize: contentView.bounds.size,
                globalProps: props
            )
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
            ShellMessageHub.register(
                info: LynxRouterPageInfo(
                    pageId: pageID,
                    containerId: pageID,
                    pageKey: request.resolvedRouteKey,
                    hostMode: "uikit_tab_container"
                ),
                view: created
            )
            LynxNativeRuntime.load(url: request.bundleURL, initData: request.initialData, in: created)
        } catch {
            showError("Tab 容器创建失败：\(error.localizedDescription)")
        }
    }

    private func showError(_ message: String) {
        guard isViewLoaded else { return }
        templateProvider?.cancel()
        templateProvider = nil
        lynxView?.removeFromSuperview()
        lynxView = nil
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

    private func releaseCurrentLease() {
        guard let lease = releaseLease else { return }
        releaseLease = nil
        Task { await lease.close() }
    }
}
