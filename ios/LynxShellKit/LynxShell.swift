import Foundation
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
    private static var installedOtaRuntime: LynxOtaRuntime?

    /** 必须在创建第一个 LynxView 前调用；内部使用 dispatch_once，重复调用安全。 */
    public static func bootstrap() {
        LynxNativeRuntime.bootstrap()
    }

    /** 绑定业务 App 实际承载 Lynx 页面的 UINavigationController。 */
    public static func attach(to navigationController: UINavigationController) {
        ShellNavigator.shared.attach(navigationController)
    }

    /** 安装 Router 内置 OTA runtime；传 nil 会关闭 appId + bundleName 页面。 */
    static func installOtaRuntime(_ runtime: LynxOtaRuntime?) {
        otaRuntimeLock.lock()
        installedOtaRuntime = runtime
        otaRuntimeLock.unlock()
    }

    /** 页面容器只读取当前安装实例，不接触 OTA 的磁盘目录或网络实现。 */
    static func otaRuntime() -> LynxOtaRuntime? {
        otaRuntimeLock.lock()
        defer { otaRuntimeLock.unlock() }
        return installedOtaRuntime
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
