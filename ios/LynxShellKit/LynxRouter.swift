import Foundation
import UIKit

/**
 * iOS 端与 Android `LynxRouter` 对齐的统一门面。
 *
 * 这里的 Native Page Stack 实现是 UINavigationController + UIViewController；业务只传
 * Bundle 与 params，不需要注册 routeId。旧的 `LynxShell` API 保留，便于已有 App 平滑迁移。
 */
public enum LynxRouter {
    /** 一次安装 Runtime 并绑定业务 App 的 UINavigationController。 */
    public static func install(to navigationController: UINavigationController) {
        LynxShell.bootstrap()
        LynxShell.attach(to: navigationController)
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
        LynxShell.installOtaRuntime(runtime)
        Task { await runtime.synchronizeAllBundles() }
        return runtime
    }

    /** App 每次回前台调用；按业务约定不做时间门控，触发 host 全量同步。 */
    public static func onApplicationForeground() {
        LynxTelemetryCoordinatorRegistry.onApplicationForeground()
        guard let runtime = LynxShell.otaRuntime() else { return }
        Task { await runtime.synchronizeAllBundles() }
    }

    /** Scene 进入后台时调用；不会把页面 hidden 误当成 App background。 */
    public static func onApplicationBackground() {
        LynxTelemetryCoordinatorRegistry.onApplicationBackground()
    }

    /** 只暴露是否已配置，不暴露 clientToken、服务地址或磁盘目录。 */
    public static var isOtaInstalled: Bool {
        LynxShell.otaRuntime() != nil
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
