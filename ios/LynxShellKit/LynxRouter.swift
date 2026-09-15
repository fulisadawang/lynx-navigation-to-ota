import Foundation
import Lynx
import UIKit

/** 原生诊断使用的聚合内存结果；不暴露实例 URL/pageId。 */
public struct LynxMemoryUsageSnapshot: Sendable {
    public let collectionStatus: String
    public let collectionStartMs: Int64
    public let collectionDurationMs: Int64
    public let collectionTimeoutMs: Int64
    public let expectedInstanceCount: Int
    public let completedInstanceCount: Int
    public let totalBytes: Int64
    public let appBytes: Int64
    public let ratioToApp: Double
    public let elementBytes: Int64
    public let elementNodeCount: Int32
    public let viewBytes: Int64
    public let mainThreadRuntimeBytes: Int64
    public let backgroundThreadRuntimeBytes: Int64
}

public extension Notification.Name {
    static let lynxOtaUserContextDidChange = Notification.Name("LynxOtaUserContextDidChange")
    static let lynxOtaUserSyncCompleted = Notification.Name("LynxOtaUserSyncCompleted")
}

/** 安装前的显式注册（包含匿名）优先于配置；只保留进程内状态。 */
private final class PendingOtaUser {
    static let shared = PendingOtaUser()
    private let lock = NSLock()
    private var explicit = false
    private var userId: String?
    func set(_ value: String?) { lock.lock(); defer { lock.unlock() }; explicit = true; userId = value }
    func get() -> (explicit: Bool, userId: String?) {
        lock.lock(); defer { lock.unlock() }; return (explicit, userId)
    }
}

/**
 * iOS 端与 Android `LynxRouter` 对齐的统一门面。
 *
 * 这里的 Native Page Stack 实现是 UINavigationController + UIViewController；业务只传
 * Bundle 与 params，不需要注册 routeId。旧的 `LynxShell` API 保留，便于已有 App 平滑迁移。
 */
public enum LynxRouter {
    /** 原生宿主注册/更新用户；无效值返回 false 且保持当前身份。 */
    @MainActor @discardableResult
    public static func registerOtaUserId(_ userId: String?) -> Bool {
        do {
            let normalized = try OtaUserContext.normalizeUserId(userId)
            let runtime = LynxShell.otaRuntime() as? LynxOtaRuntime
            let changed = try runtime?.registerUserId(normalized) ?? false
            PendingOtaUser.shared.set(normalized)
            if changed, let runtime {
                NotificationCenter.default.post(name: .lynxOtaUserContextDidChange, object: runtime,
                                                userInfo: ["epoch": runtime.userIdentityEpoch])
            }
            return true
        } catch {
            NSLog("[LynxShell][OTA] 用户注册参数无效")
            return false
        }
    }

    @MainActor @discardableResult
    public static func clearOtaUserId() -> Bool { registerOtaUserId(nil) }

    public static var otaUserIdentityEpoch: UInt64? {
        (LynxShell.otaRuntime() as? LynxOtaRuntime)?.userIdentityEpoch
    }
    /** 一次安装 Runtime 并绑定业务 App 的 UINavigationController。 */
    public static func install(to navigationController: UINavigationController) {
        LynxShell.bootstrap()
        LynxShell.attach(to: navigationController)
        // 即使宿主没有配置远程 OTA，也要让带 appId 的内置 Bundle 可以按 Registry 打开。
        LynxShell.installOtaRuntime(LynxEmbeddedOnlyRuntime())
    }

    /**
     * 一体化 OTA 安装入口。
     *
     * 宿主只需 import LynxShellKit；Manifest、下载、SHA、current/previous 和回滚均由
     * Router 内置 OTA 引擎承担。安装后异步执行一次 host 全量 appId 同步，不阻塞原生首页显示。
     */
    @discardableResult
    public static func install(
        to navigationController: UINavigationController,
        otaConfiguration: LynxOtaConfiguration
    ) throws -> LynxOtaRuntime {
        install(to: navigationController)
        let runtime = try LynxOtaRuntime(configuration: otaConfiguration)
        let pending = PendingOtaUser.shared.get()
        if pending.explicit { try runtime.registerInitialUserId(pending.userId) }
        LynxShell.installOtaRuntime(runtime)
#if DEBUG
        if ProcessInfo.processInfo.environment["LYNX_TEST_SKIP_STARTUP_SYNC"] == "1" {
            return runtime
        }
#endif
        Task {
            await runtime.registerEmbeddedReleases()
            _ = await runtime.synchronizeAllBundles(coalesce: true)
        }
        return runtime
    }

#if DEBUG
private enum OtaDebugF12Status {
    private static let key = "lynx.shell.debug.f12.status"

    static func set(_ value: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    static func get() -> String {
        UserDefaults.standard.string(forKey: key) ?? "idle"
    }
}

    /**
     * XCUITest 专用故障入口；只在 Debug 编译和显式环境变量下替换 runtime。
     * 不进入 Release，且仍使用 App Bundle 的真实 Lynx 字节验证容器回滚。
     */
    @discardableResult
    public static func installDebugFaultRuntimeIfRequested() -> Bool {
        guard let rawScenario = ProcessInfo.processInfo.environment[
            "LYNX_TEST_FAULT_SCENARIO"
        ],
              let scenario = LynxDebugFaultRuntime.Scenario(rawValue: rawScenario) else {
            return false
        }
        LynxShell.installOtaRuntime(LynxDebugFaultRuntime(scenario: scenario))
        return true
    }

    /** 外网不可用时启用进程内 OTA 语义模拟器；只在 Debug + 显式环境变量下生效。 */
    @discardableResult
    public static func installDebugMockOtaRuntimeIfRequested() -> Bool {
        guard ProcessInfo.processInfo.environment["LYNX_TEST_MOCK_OTA"] == "1" else {
            return false
        }
        LynxShell.installOtaRuntime(LynxDebugMockOtaRuntime())
        return true
    }
#endif

    /** App 每次回前台调用；按业务约定不做时间门控，触发 host 全量同步。 */
    public static func onApplicationForeground() {
#if DEBUG
        if ProcessInfo.processInfo.environment["LYNX_TEST_SKIP_STARTUP_SYNC"] == "1" {
            return
        }
#endif
        guard let runtime = LynxShell.otaRuntime() as? LynxOtaRuntime else { return }
        Task { await runtime.synchronizeAllBundles() }
    }

    /** Demo/宿主主动刷新全量 OTA；返回是否完成了一次可用的全量同步。 */
    public static func refreshAllOtaBundles() async -> Bool {
        if let runtime = LynxShell.otaRuntime() as? LynxOtaRuntime {
            return await runtime.synchronizeAllBundles(coalesce: true)
        }
#if DEBUG
        if let runtime = LynxShell.otaRuntime() as? LynxDebugMockOtaRuntime {
            return await runtime.synchronizeAllBundles()
        }
#endif
        return false
    }

#if DEBUG
    /** XCUITest F12 准备真实 current/previous downloaded pair；Release 不暴露。 */
    public static func debugPrepareRollbackProcessTest() async -> String {
        OtaDebugF12Status.set("starting")
        guard let runtime = LynxShell.otaRuntime() as? LynxOtaRuntime,
              let identity = embeddedIdentity(bundleName: "home.lynx.bundle") else {
            OtaDebugF12Status.set("runtime_or_manifest_missing")
            return "runtime_or_manifest_missing"
        }
        OtaDebugF12Status.set("seeding")
        do {
            try await runtime.debugSeedRollbackPair(
                lynxAppId: identity.lynxAppId,
                bundleName: identity.bundleName
            )
            OtaDebugF12Status.set("seeded")
            return "ok"
        } catch {
            let result = "seed_failed:\(error.localizedDescription)"
            OtaDebugF12Status.set(result)
            return result
        }
    }

    public static var debugF12Status: String {
        OtaDebugF12Status.get()
    }
#endif

    /** 只暴露是否已配置，不暴露 clientToken、服务地址或磁盘目录。 */
    public static var isOtaInstalled: Bool {
        if LynxShell.otaRuntime() is LynxOtaRuntime { return true }
#if DEBUG
        if LynxShell.otaRuntime() is LynxDebugMockOtaRuntime { return true }
#endif
        return false
    }

#if DEBUG
    /** Debug/XCUITest 读取真实 ServerOtaAPIClient 的请求数；Release 不暴露。 */
    public static var debugHTTPRequestCount: Int {
        OtaDebugHTTPMetrics.snapshot()
    }

    public static func resetDebugHTTPRequestCount() {
        OtaDebugHTTPMetrics.reset()
    }
#endif

    /**
     * 仅供宿主 Demo/Coordinator 使用：让宿主 UINavigationController 统一管理返回手势。
     * 业务 App 默认保持 false，继续使用壳按页面的转场/手势策略。
     */
    public static func setHostManagedBackGesture(_ enabled: Bool) {
        LynxShell.setHostManagedBackGesture(enabled)
    }

    /** 返回当前 App 语言；语言资源由各个 Lynx Bundle 自己加载。 */
    public static func currentLocale() -> LynxLocaleState {
        ShellLocaleStore.current()
    }

    /** 设置 App 语言并同步所有存活 LynxView；nil 清除覆盖并恢复跟随系统。 */
    @discardableResult
    public static func setLocale(_ locale: String?) throws -> LynxLocaleState {
        let previous = ShellLocaleStore.current()
        let state = try ShellLocaleStore.set(appLocale: locale)
        if state != previous {
            _ = ShellMessageHub.updateLocale(state)
        }
        return state
    }

    /** 清除 App 语言覆盖，等价于 setLocale(nil)。 */
    @discardableResult
    public static func clearLocale() throws -> LynxLocaleState {
        try setLocale(nil)
    }

    /**
     * 打开 assets/HTTPS Bundle；params 同时作为 initData 和 queryItems。
     *
     * HTTPS 在这里属于“直接远程 Bundle”：Provider 按原 URL 加载，不反查 lynxAppId，
     * 也不进入 OTA Manifest、磁盘 Release、页面刷新门控或回滚链路。需要 OTA 管理的页面
     * 必须使用独立的 `lynxAppId + bundleName` 契约，不能把远程 URL 冒充 bundleName。
     */
    @discardableResult
    public static func open(
        bundle: String,
        params: [String: Any] = [:],
        options: [String: Any] = [:]
    ) throws -> LynxShellResult {
        let optionsJSON = try optionsJSON(params: params, options: options)
        return try LynxShell.open(bundle, optionsJSON: optionsJSON)
    }

    /**
     * 打开 iOS Native Page Stack OTA 页面。
     *
     * 导航栈只持有逻辑 `lynxAppId + bundleName`，不会持久化 current 的绝对沙盒路径。
     * Container 若命中已校验 current 会立即加载；缺包/损坏时显示原生 Loading 并等待修复。
     */
    @discardableResult
    public static func open(
        lynxAppId: String,
        bundleName: String,
        params: [String: Any] = [:],
        options: [String: Any] = [:]
    ) throws -> LynxShellResult {
        var otaOptions = options
        otaOptions["lynxAppId"] = lynxAppId
        otaOptions["bundleName"] = bundleName
        let optionsJSON = try optionsJSON(params: params, options: otaOptions)
        return try LynxShell.open(bundleName, optionsJSON: optionsJSON)
    }

    /** Demo/宿主发现入口：App ID 和 BundleName 来自内置 Manifest，不由代码猜测。 */
    @discardableResult
    public static func openFirstEmbedded(
        params: [String: Any] = [:],
        options: [String: Any] = [:]
    ) throws -> LynxShellResult {
        guard let identity = EmbeddedBundleRegistry().firstIdentity() else {
            throw NSError(
                domain: "LynxShellEmbedded",
                code: 1007,
                userInfo: [NSLocalizedDescriptionKey: "内置 Manifest 没有可用 Bundle"]
            )
        }
        return try open(
            lynxAppId: identity.lynxAppId,
            bundleName: identity.bundleName,
            params: params,
            options: options
        )
    }

    /** 按 embedded Manifest 的 BundleName 找到对应 App ID，再走统一 OTA/embedded 选择链路。 */
    @discardableResult
    public static func openEmbedded(
        bundleName: String,
        params: [String: Any] = [:],
        options: [String: Any] = [:]
    ) throws -> LynxShellResult {
        guard let identity = EmbeddedBundleRegistry().identity(bundleName: bundleName) else {
            throw NSError(
                domain: "LynxShellEmbedded",
                code: 1008,
                userInfo: [NSLocalizedDescriptionKey: "内置 Manifest 没有找到 Bundle：\(bundleName)"]
            )
        }
        return try open(
            lynxAppId: identity.lynxAppId,
            bundleName: identity.bundleName,
            params: params,
            options: options
        )
    }

    /** 返回 embedded Manifest 中的真实 Bundle 身份，供 Native Tab Descriptor 使用。 */
    public static func embeddedIdentity(
        bundleName: String
    ) -> (lynxAppId: String, bundleName: String)? {
        EmbeddedBundleRegistry().identity(bundleName: bundleName)
    }

    /** 直接删除指定 appId 的下载 Bundle；embedded 描述和 App 内置资源保留。 */
    public static func deleteOtaBundles(lynxAppId: String) async throws {
        guard let runtime = LynxShell.otaRuntime() else {
            throw LynxOtaError.runtimeNotInstalled
        }
        try await runtime.deleteBundles(lynxAppId: lynxAppId)
    }

    /** 直接删除全部 appId 下载 Bundle；不会生成 `.delete-*` 备份目录。 */
    public static func deleteAllOtaBundles() async throws {
        guard let runtime = LynxShell.otaRuntime() else {
            throw LynxOtaError.runtimeNotInstalled
        }
        try await runtime.deleteAllBundles()
    }

    /** 只读 OTA Store 快照；不联网、不激活、不删除文件。 */
    public static func otaStorageSnapshot() async throws -> OtaStorageSnapshot? {
        guard let runtime = LynxShell.otaRuntime() else {
            throw LynxOtaError.runtimeNotInstalled
        }
        return try await runtime.storageSnapshot()
    }

    /**
     * 按需读取当前进程内 Lynx 实例的聚合内存快照。
     *
     * 回调会切回主线程，结果只包含聚合值、状态和实例计数，不进入 LynxShellModule 或
     * OTA 上报。timeoutMilliseconds 小于等于 0 时沿用 Lynx 4.1 的 2000ms 默认值。
     */
    public static func queryMemoryUsage(
        timeoutMilliseconds: Int64 = 0,
        completion: @escaping (LynxMemoryUsageSnapshot) -> Void
    ) {
        let callback: (LynxGlobalMemoryUsageResult) -> Void = { result in
            let snapshot = LynxMemoryUsageSnapshot(
                collectionStatus: result.collectionStatus.rawValue == 0 ? "completed" : "timeout",
                collectionStartMs: result.collectionStartMs,
                collectionDurationMs: result.collectionDurationMs,
                collectionTimeoutMs: result.collectionTimeoutMs,
                expectedInstanceCount: result.expectedInstanceCount,
                completedInstanceCount: result.completedInstanceCount,
                totalBytes: result.totalBytes,
                appBytes: result.appBytes,
                ratioToApp: result.ratioToApp,
                elementBytes: result.elementBytes,
                elementNodeCount: result.elementNodeCount,
                viewBytes: result.viewBytes,
                mainThreadRuntimeBytes: result.mainThreadRuntimeBytes,
                backgroundThreadRuntimeBytes: result.backgroundThreadRuntimeBytes
            )
            DispatchQueue.main.async {
                completion(snapshot)
            }
        }
        LynxMemoryUsageQuery.sharedInstance().queryLynxGlobalMemoryUsageAsync(
            callback,
            timeoutMs: timeoutMilliseconds
        )
    }

    /** 打开 `hybrid://lynxview_page?...` 或其它兼容 Scheme。 */
    @discardableResult
    public static func openScheme(
        _ scheme: String,
        params: [String: Any] = [:],
        options: [String: Any] = [:]
    ) throws -> LynxShellResult {
        let optionsJSON = try optionsJSON(params: params, options: options)
        return try LynxShell.open(scheme, optionsJSON: optionsJSON)
    }

    /** 原位替换当前 Lynx 页面，保持当前 entry 的页面身份。 */
    @discardableResult
    public static func replace(
        bundle: String,
        params: [String: Any] = [:],
        options: [String: Any] = [:]
    ) throws -> LynxShellResult {
        let optionsJSON = try optionsJSON(params: params, options: options)
        let request = try LynxRouteParser.request(from: bundle, optionsJSON: optionsJSON)
        let navigationOptions = try ShellNavigationOptions.fromJSON(optionsJSON)
        return LynxShellResult(
            ShellNavigator.shared.redirect(request, options: navigationOptions)
        )
    }

    /** 关闭当前页面；如果已经是 session 首页，则回到宿主锚点。 */
    @discardableResult
    public static func pop() -> LynxShellResult {
        LynxShellResult(ShellNavigator.shared.close())
    }

    /** 回到当前 session 中最近的目标 Bundle/pageKey。 */
    @discardableResult
    public static func popTo(_ pageKey: String) -> LynxShellResult {
        LynxShellResult(ShellNavigator.shared.popTo(routeKey: pageKey))
    }

    /** 关闭当前 Lynx session。 */
    @discardableResult
    public static func closeAll() -> LynxShellResult {
        LynxShellResult(ShellNavigator.shared.closeAll())
    }

    /** 清空当前 session 并回到宿主主页；目标页面由宿主随后调用 open 提供。 */
    @discardableResult
    public static func reLaunch(options: [String: Any] = [:]) throws -> LynxShellResult {
        let optionsJSON = try encode(options)
        let navigationOptions = try ShellNavigationOptions.fromJSON(optionsJSON)
        return LynxShellResult(
            ShellNavigator.shared.reLaunch(
                optionsJSON: optionsJSON,
                navigationOptions: navigationOptions
            )
        )
    }

    /** 清空当前 session 后打开新的目标 Bundle；与 Android/Harmony `reLaunch` 对齐。 */
    @discardableResult
    public static func reLaunch(
        bundle: String,
        params: [String: Any] = [:],
        options: [String: Any] = [:]
    ) throws -> LynxShellResult {
        let closed = closeAll()
        guard closed.isSuccess else { return closed }
        return try open(bundle: bundle, params: params, options: options)
    }

    /** 注册宿主的 JS -> Native 双向消息处理器。 */
    public static func setMessageHandler(_ handler: LynxRouterMessageHandler?) {
        ShellMessageHub.setMessageHandler(handler)
    }

    /** 返回当前进程内仍持有 LynxView 的页面实例。 */
    public static func activePages() -> [LynxRouterPageInfo] {
        ShellMessageHub.pages()
    }

    /** 向所有活体 Lynx 页面发送 GlobalEvent。 */
    @discardableResult
    public static func broadcast(
        _ eventName: String,
        payload: [String: Any] = [:]
    ) throws -> Int {
        try ShellMessageHub.broadcast(eventName: eventName, payload: payload)
    }

    /** 向一个页面实例发送 GlobalEvent。 */
    public static func sendToPage(
        _ pageId: String,
        eventName: String,
        payload: [String: Any] = [:]
    ) throws -> Bool {
        try ShellMessageHub.sendToPage(pageId: pageId, eventName: eventName, payload: payload)
    }

    private static func optionsJSON(
        params: [String: Any],
        options: [String: Any]
    ) throws -> String {
        var merged = options
        if !params.isEmpty {
            merged["initData"] = params
            var globalProps = merged["globalProps"] as? [String: Any] ?? [:]
            globalProps["queryItems"] = params
            merged["globalProps"] = globalProps
        }
        return try encode(merged)
    }

    private static func encode(_ value: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw NSError(domain: "LynxRouter", code: 1001, userInfo: [
                NSLocalizedDescriptionKey: "params/options 必须是 JSON Object",
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: value, options: [])
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "LynxRouter", code: 1001, userInfo: [
                NSLocalizedDescriptionKey: "params/options 编码失败",
            ])
        }
        return json
    }
}
