import LynxShellKit
import UIKit

/** Scene 只负责建立系统导航栈，并把深链交给统一 Router。 */
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        // 原生 Launcher 始终作为宿主页锚点；启动后不再自动 push main.lynx.bundle。
        let rootController = LauncherViewController()
        let navigationController = UINavigationController(rootViewController: rootController)
        navigationController.navigationBar.prefersLargeTitles = true
        // 三端统一入口：iOS 端 Native Page Stack 由 UINavigationController 承载。
        // Demo 不硬编码令牌。业务可从 Info.plist 或进程环境注入配置；配置完整时安装
        // Router 内置 OTA 引擎；即使未配置 OTA，仍可验收本地/HTTPS Direct Bundle。
        if let otaConfiguration = Self.makeOtaConfiguration() {
            do {
                try LynxRouter.install(
                    to: navigationController,
                    otaConfiguration: otaConfiguration
                )
            } catch {
                LynxRouter.install(to: navigationController)
                NSLog("[LynxShell] OTA 配置无效：%@", error.localizedDescription)
            }
        } else {
            LynxRouter.install(to: navigationController)
        }
        LynxShell.installAppHomeHandler { navigationController, _ in
            // 壳工程没有真实 UITabBarController，示例回到原生首页。
            // 业务 App 在 Scene/Coordinator 中覆盖为“选择主 Tab + popToRoot”。
            navigationController.popToRootViewController(animated: false)
            return true
        }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = navigationController
        window.makeKeyAndVisible()
        self.window = window

        if let url = connectionOptions.urlContexts.first?.url {
            // 根控制器完成显示后再执行 push / alert，避免冷启动深链出现层级告警。
            DispatchQueue.main.async { [weak self] in self?.openDeepLink(url) }
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        openDeepLink(url)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL else { return }
        openDeepLink(url)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        LynxRouter.onApplicationBackground()
        LynxShell.sceneDidEnterBackground()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        LynxRouter.onApplicationForeground()
    }

    private func openDeepLink(_ url: URL) {
        do {
            _ = try LynxRouter.openScheme(url.absoluteString)
        } catch {
            (window?.rootViewController as? UINavigationController)?.topViewController?
                .presentShellAlert(title: "无法打开 Lynx 页面", message: error.localizedDescription)
        }
    }

    /**
     * Sample 配置入口：优先读取进程环境，随后读取 Info.plist。
     *
     * 不提供默认 token，避免把真实凭据提交到仓库；正式 App 应接自己的安全配置层。
     */
    private static func makeOtaConfiguration() -> LynxOtaConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        let info = Bundle.main.infoDictionary ?? [:]
        let baseValue = environment["LYNX_OTA_API_BASE_URL"]
            ?? info["LynxOtaAPIBaseURL"] as? String
        let token = environment["LYNX_OTA_CLIENT_TOKEN"]
            ?? info["LynxOtaClientToken"] as? String
        guard let baseValue,
              let apiBaseURL = URL(string: baseValue),
              let token,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return LynxOtaConfiguration(
            apiBaseURL: apiBaseURL,
            hostApp: environment["LYNX_OTA_HOST_APP"]
                ?? info["LynxOtaHostApp"] as? String
                ?? "capp",
            defaultLynxAppId: "10000001",
            environment: environment["LYNX_OTA_ENV"]
                ?? info["LynxOtaEnvironment"] as? String
                ?? "TEST",
            clientToken: token
        )
    }

}
