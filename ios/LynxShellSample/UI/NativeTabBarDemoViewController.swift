import LynxShellKit
import UIKit

/**
 * iOS sample-only Tab Host。
 *
 * UITabBarController 只负责系统 TabBar 和选中态；每个 child 都是库层提供的
 * LynxTabViewController。设置 `LYNX_TEST_OTA_V3_FIXTURE=1` 时，两个 Tab 会读取本地
 * Golden Fixture 的 current；普通运行仍从 embedded Manifest 解析 Bundle 身份。
 * 移除这个文件不会影响 LynxShellKit 的无 Tab 容器能力。
 */
final class NativeTabBarDemoViewController: UITabBarController {
    private var tabControllers: [LynxTabViewController] = []
    private var refreshItem: UIBarButtonItem?
    private let otaV3FixtureEnabled = ProcessInfo.processInfo.environment[
        "LYNX_TEST_OTA_V3_FIXTURE"
    ] == "1"
#if DEBUG
    private var debugStateLabel: UILabel?
    private var debugStateTimer: Timer?
#endif

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
        let storageItem = UIBarButtonItem(
            title: "磁盘",
            style: .plain,
            target: self,
            action: #selector(openStorageInspector)
        )
        storageItem.accessibilityIdentifier = "native-tab-storage-inspector"
        navigationItem.rightBarButtonItems = [refreshItem, storageItem]
        self.refreshItem = refreshItem
#if DEBUG
        if ProcessInfo.processInfo.environment["LYNX_UI_TEST_EXPOSE_RUNTIME_STATE"] == "1" {
            let rebuildItem = UIBarButtonItem(
                title: "重建 Tab",
                style: .plain,
                target: self,
                action: #selector(debugRebuildSelectedTab)
            )
            navigationItem.rightBarButtonItems = [refreshItem, storageItem, rebuildItem]
        }
#endif

        let identity = otaV3FixtureEnabled
            ? (lynxAppId: "10000001", bundleName: "pages/10000001/bundle-050.lynx.bundle")
            : LynxRouter.embeddedIdentity(bundleName: "main.lynx.bundle")
        guard let identity else {
            presentShellAlert(
                title: "Tab Bundle 不可用",
                message: "embedded Manifest 没有找到 main.lynx.bundle 的 App ID"
            )
            return
        }

        let home = LynxTabViewController(
            spec: LynxTabSpec(
                tabId: "home",
                bundleURL: otaV3FixtureEnabled
                    ? identity.bundleName
                    : "assets://bundles/main.lynx.bundle",
                title: otaV3FixtureEnabled ? "首页（OTA v3）" : "首页",
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
                bundleURL: otaV3FixtureEnabled
                    ? identity.bundleName
                    : "assets://bundles/main.lynx.bundle",
                title: otaV3FixtureEnabled ? "设置（OTA v3）" : "设置",
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
#if DEBUG
        installDebugStateIfNeeded()
#endif
    }

#if DEBUG
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard ProcessInfo.processInfo.environment["LYNX_UI_TEST_EXPOSE_RUNTIME_STATE"] == "1" else {
            return
        }
        updateDebugState()
        debugStateTimer?.invalidate()
        debugStateTimer = Timer.scheduledTimer(
            withTimeInterval: 0.1,
            repeats: true
        ) { [weak self] _ in
            self?.updateDebugState()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        debugStateTimer?.invalidate()
        debugStateTimer = nil
    }

    deinit {
        debugStateTimer?.invalidate()
    }

    private func installDebugStateIfNeeded() {
        guard ProcessInfo.processInfo.environment["LYNX_UI_TEST_EXPOSE_RUNTIME_STATE"] == "1" else {
            return
        }
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.accessibilityIdentifier = "lynx-debug-tab-state"
        label.accessibilityTraits = .staticText
        label.font = UIFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        label.textColor = .secondaryLabel
        label.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
        label.numberOfLines = 2
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.55
        label.textAlignment = .center
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            label.heightAnchor.constraint(equalToConstant: 30),
        ])
        debugStateLabel = label
        updateDebugState()
    }

    private func updateDebugState() {
        guard let label = debugStateLabel else { return }
        let values = tabControllers.map { tab in
            "\(tab.spec.tabId)=\(tab.debugState)"
        }
        let value = values.joined(separator: " | ") +
            " | http=\(LynxRouter.debugHTTPRequestCount)"
        label.text = value
        label.accessibilityValue = value
    }
#endif

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

    @objc private func openStorageInspector() {
        navigationController?.pushViewController(
            OtaStorageInspectorViewController(),
            animated: true
        )
    }

#if DEBUG
    @objc private func debugRebuildSelectedTab() {
        guard let selected = selectedViewController as? LynxTabViewController else { return }
        selected.refreshFromCurrent()
        updateDebugState()
    }
#endif
}
