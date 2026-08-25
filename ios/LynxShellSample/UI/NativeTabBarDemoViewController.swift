import LynxShellKit
import UIKit

/**
 * iOS sample-only Tab Host。
 *
 * UITabBarController 只负责系统 TabBar 和选中态；每个 child 都是库层提供的
 * LynxTabViewController。移除这个文件不会影响 LynxShellKit 的无 Tab 容器能力。
 */
final class NativeTabBarDemoViewController: UITabBarController {
    private var tabControllers: [LynxTabViewController] = []
    private var refreshItem: UIBarButtonItem?

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Launcher 为了沉浸式首页隐藏了导航栏；进入原生 Tab Demo 后恢复全局导航承载。
        navigationController?.setNavigationBarHidden(false, animated: false)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "原生 Tab 承载 Demo"
        view.backgroundColor = .systemBackground

        let refreshItem = UIBarButtonItem(
            title: "刷新 OTA",
            style: .plain,
            target: self,
            action: #selector(refreshOta)
        )
        navigationItem.rightBarButtonItem = refreshItem
        self.refreshItem = refreshItem

        guard let identity = LynxRouter.embeddedIdentity(bundleName: "main.lynx.bundle") else {
            presentShellAlert(
                title: "Tab Bundle 不可用",
                message: "embedded Manifest 没有找到 main.lynx.bundle 的 App ID"
            )
            return
        }

        let home = LynxTabViewController(
            spec: LynxTabSpec(
                tabId: "home",
                bundleURL: "assets://bundles/main.lynx.bundle",
                title: "首页",
                routeKey: "native-tab-home",
                initialData: ["source": "native-tab-demo"],
                globalProps: [
                    "queryItems": ["native_tab_id": "home"],
                ],
                lynxAppId: identity.lynxAppId,
                bundleName: identity.bundleName
            )
        )
        home.tabBarItem = UITabBarItem(
            title: "首页",
            image: UIImage(systemName: "house"),
            selectedImage: UIImage(systemName: "house.fill")
        )

        let settings = LynxTabViewController(
            spec: LynxTabSpec(
                tabId: "settings",
                bundleURL: "assets://bundles/main.lynx.bundle",
                title: "设置",
                routeKey: "native-tab-settings",
                initialData: ["source": "native-tab-demo"],
                globalProps: [
                    "queryItems": ["native_tab_id": "settings"],
                ],
                lynxAppId: identity.lynxAppId,
                bundleName: identity.bundleName
            )
        )
        settings.tabBarItem = UITabBarItem(
            title: "设置",
            image: UIImage(systemName: "gearshape"),
            selectedImage: UIImage(systemName: "gearshape.fill")
        )

        tabControllers = [home, settings]
        setViewControllers(tabControllers, animated: false)
    }

    @objc private func refreshOta() {
        refreshItem?.isEnabled = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            let success = await LynxRouter.refreshAllOtaBundles()
            if success {
                tabControllers.forEach { $0.refreshFromCurrent() }
            }
            refreshItem?.isEnabled = true
            presentShellAlert(
                title: success ? "OTA 同步完成" : "OTA 同步失败",
                message: success
                    ? "Tab 已重新读取当前已提交 Bundle"
                    : "保留当前 Tab 版本，请检查 OTA 配置和网络"
            )
        }
    }
}
