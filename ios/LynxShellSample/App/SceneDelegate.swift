import LynxShellKit
import UIKit

/**
 * iOS Demo 专用的全局导航承载。
 *
 * 业务 App 可以选择自己的 UINavigationController；Sample 为了方便验收，始终让宿主
 * 全局管理 interactive-pop，不依赖每个 Lynx 页面是否声明 transition。
 */
final class DemoNavigationController: UINavigationController {
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        enableGlobalBackGesture()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        enableGlobalBackGesture()
    }

    private func enableGlobalBackGesture() {
        guard isViewLoaded else { return }
        interactivePopGestureRecognizer?.delegate = nil
        interactivePopGestureRecognizer?.isEnabled = viewControllers.count > 1
    }
}

/** Scene 只负责建立系统导航栈，并把深链交给统一 Router。 */
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        // 原生 Launcher 始终作为宿主页锚点；默认冷启动在 Window 就绪后 push OTA 验收首页。
        let rootController = LauncherViewController()
        let navigationController = DemoNavigationController(rootViewController: rootController)
        navigationController.navigationBar.prefersLargeTitles = true
#if DEBUG
        // Sample 只为验收开启宿主全局返回；生产宿主不应默认覆盖业务自己的手势策略。
        LynxRouter.setHostManagedBackGesture(true)
#endif
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

        var shouldOpenBottomSheetDemo = false
        var shouldOpenHeroSheetDemo = false
        var shouldOpenNativeTabDemo = false
        var shouldOpenEmbeddedDemo = false
#if DEBUG
        shouldOpenBottomSheetDemo = ProcessInfo.processInfo.arguments.contains(
            "--bottom-sheet-demo"
        )
        shouldOpenHeroSheetDemo = ProcessInfo.processInfo.arguments.contains(
            "--hero-sheet-demo"
        )
        shouldOpenNativeTabDemo = ProcessInfo.processInfo.arguments.contains(
            "--native-tab-demo"
        )
        shouldOpenEmbeddedDemo = ProcessInfo.processInfo.arguments.contains(
            "--embedded-demo"
        )
#endif
        if let url = connectionOptions.urlContexts.first?.url {
            // 根控制器完成显示后再执行 push / alert，避免冷启动深链出现层级告警。
            DispatchQueue.main.async { [weak self] in self?.openDeepLink(url) }
        } else if shouldOpenHeroSheetDemo {
#if DEBUG
            DispatchQueue.main.async { [weak self] in self?.openHeroSheetDemo() }
#endif
        } else if shouldOpenBottomSheetDemo {
#if DEBUG
            DispatchQueue.main.async { [weak self] in self?.openBottomSheetDemo() }
#endif
        } else if shouldOpenNativeTabDemo {
#if DEBUG
            DispatchQueue.main.async { [weak self] in self?.openNativeTabDemo() }
#endif
        } else if shouldOpenEmbeddedDemo {
#if DEBUG
            DispatchQueue.main.async { [weak self] in self?.openEmbeddedDemo() }
#endif
        } else if !ProcessInfo.processInfo.arguments.contains("--show-native-launcher") {
            // 与 Android MainActivity 一致：冷启动默认进入 OTA 验收首页；
            // Playground main 页面仍通过 Launcher 的独立按钮打开。
            DispatchQueue.main.async { [weak self] in self?.openOtaAcceptanceHome() }
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

    private func openPlaygroundHome() {
        do {
            _ = try LynxRouter.openEmbedded(
                bundleName: "main.lynx.bundle",
                params: ["source": "ios-playground-home"],
                options: [
                    "title": "Sparkling Go",
                    "fullscreen": true,
                    "showNavigationBar": false,
                ]
            )
        } catch {
            (window?.rootViewController as? UINavigationController)?.topViewController?
                .presentShellAlert(
                    title: "无法打开 Playground 首页",
                    message: error.localizedDescription
                )
        }
    }

    private func openOtaAcceptanceHome() {
        do {
            _ = try LynxRouter.openEmbedded(
                bundleName: "home.lynx.bundle",
                params: [
                    "source": "ios-ota-acceptance-home",
                    "acceptance": true,
                ],
                options: [
                    "title": "OTA 验收首页",
                    "fullscreen": true,
                    "showNavigationBar": false,
                ]
            )
        } catch {
            (window?.rootViewController as? UINavigationController)?.topViewController?
                .presentShellAlert(
                    title: "无法打开 OTA 验收首页",
                    message: error.localizedDescription
                )
        }
    }

    private func openNativeTabDemo() {
        guard let navigationController = window?.rootViewController as? UINavigationController else {
            return
        }
        navigationController.pushViewController(
            NativeTabBarDemoViewController(),
            animated: false
        )
    }

    private func openEmbeddedDemo() {
        do {
            _ = try LynxRouter.openFirstEmbedded(
                params: ["source": "ios-embedded-manifest-debug"],
                options: ["title": "内置 Bundle Demo"]
            )
        } catch {
            (window?.rootViewController as? UINavigationController)?.topViewController?
                .presentShellAlert(
                    title: "无法打开内置 Bundle",
                    message: error.localizedDescription
                )
        }
    }

#if DEBUG
    /** 自动化验收入口：先建立来源页面，再由公开 Router 打开 iOS 系统 Page Sheet。 */
    private func openBottomSheetDemo() {
        do {
            _ = try LynxRouter.open(
                bundle: "assets://bundles/transition-gallery.lynx.bundle",
                params: ["source": "ios-bottom-sheet-demo"],
                options: [
                    "title": "原生容器转场",
                    "fullscreen": true,
                    "showNavigationBar": false,
                ]
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                do {
                    _ = try LynxRouter.open(
                        bundle: "assets://bundles/transition-detail.lynx.bundle",
                        params: [
                            "title": "bottomSheet",
                            "transition_kind": "bottomSheet",
                            "force_theme_style": "light",
                            "container_bg_color": "#F4F4F5",
                        ],
                        options: [
                            "routeKey": "transition-bottomSheet",
                            "routeType": "wx://bottom-sheet",
                        ]
                    )
                } catch {
                    self?.presentLaunchError(error)
                }
            }
        } catch {
            presentLaunchError(error)
        }
    }

    /** 自动化验收入口：直接打开 Lynx 自己控制滚动的透明 heroSheet。 */
    private func openHeroSheetDemo() {
        do {
            _ = try LynxRouter.open(
                bundle: "assets://bundles/transition-gallery.lynx.bundle",
                params: ["source": "ios-hero-sheet-demo"],
                options: [
                    "title": "原生容器转场",
                    "fullscreen": true,
                    "showNavigationBar": false,
                ]
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                do {
                    _ = try LynxRouter.open(
                        bundle: "assets://bundles/transition-detail.lynx.bundle",
                        params: [
                            "title": "heroSheet",
                            "transition_kind": "heroSheet",
                            "force_theme_style": "light",
                            "container_bg_color": "#F4F4F5",
                        ],
                        options: [
                            "routeKey": "transition-heroSheet",
                            "routeType": "wx://hero-sheet",
                            "transparent": true,
                            "animated": false,
                            "transition": [
                                "popGesture": [
                                    "enabled": true,
                                    "direction": "vertical",
                                    "fullScreen": true,
                                ],
                            ],
                            "routeOptions": [
                                "detents": [28, 56, 100],
                                "initialDetent": 56,
                            ],
                        ]
                    )
                } catch {
                    self?.presentLaunchError(error)
                }
            }
        } catch {
            presentLaunchError(error)
        }
    }

    private func presentLaunchError(_ error: Error) {
        (window?.rootViewController as? UINavigationController)?.topViewController?
            .presentShellAlert(
                title: "无法打开 Bottom Sheet 验收页",
                message: error.localizedDescription
            )
    }
#endif

    /**
     * Sample 配置入口：优先读取进程环境，随后读取 Info.plist。
     *
     * 不提供默认 token，避免把真实凭据提交到仓库；正式 App 应接自己的安全配置层。
     */
    private static func makeOtaConfiguration() -> LynxOtaConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        let info = Bundle.main.infoDictionary ?? [:]
        let baseValue = Self.configurationValue(
            environment["LYNX_OTA_API_BASE_URL"]
                ?? info["LynxOtaAPIBaseURL"] as? String
        )
        let token = Self.configurationValue(
            environment["LYNX_OTA_CLIENT_TOKEN"]
                ?? info["LynxOtaClientToken"] as? String
        )
        guard let baseValue,
              let apiBaseURL = URL(string: baseValue),
              let token,
              apiBaseURL.scheme?.lowercased() == "https",
              apiBaseURL.host?.isEmpty == false else {
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

    private static func configurationValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }

}
