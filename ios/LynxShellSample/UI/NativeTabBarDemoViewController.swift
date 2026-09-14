import LynxShellKit
import UIKit

/**
 * iOS sample-only Tab Host。
 *
 * UITabBarController 只负责系统 TabBar 和选中态；每个 child 都是库层提供的
 * LynxTabViewController。设置 `LYNX_TEST_OTA_V3_FIXTURE=1` 时，两个 Tab 会读取本地
 * Golden Fixture 的 current；普通运行直接读取 Bundles 根目录的最新 Playground Bundle。
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
        synchronizeTabColorScheme()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection == nil ||
                previousTraitCollection!.hasDifferentColorAppearance(comparedTo: traitCollection) else {
            return
        }
        synchronizeTabColorScheme()
    }

    private func synchronizeTabColorScheme() {
        tabControllers.forEach { $0.synchronizeColorScheme(with: traitCollection) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "原生 Tab 承载 Demo"
        navigationItem.largeTitleDisplayMode = .never
        // Demo 的 Lynx 内容在导航栏下方起始，避免 iOS 26 透明导航遮住版本标记。
        edgesForExtendedLayout = []
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
        if ProcessInfo.processInfo.environment["LYNX_TEST_OTA_USER_SELECTION"] == "1" {
            let userItem = UIBarButtonItem(title: "用户", style: .plain, target: self, action: #selector(selectOtaUser))
            userItem.accessibilityIdentifier = "ota-select-user"
            // iOS 26 会把过多按钮收进 More；验收入口固定为两个可见按钮。
            navigationItem.rightBarButtonItems = [refreshItem, userItem]
        }
#if DEBUG
        if ProcessInfo.processInfo.environment["LYNX_UI_TEST_EXPOSE_RUNTIME_STATE"] == "1",
           ProcessInfo.processInfo.environment["LYNX_TEST_OTA_USER_SELECTION"] != "1" {
            let rebuildItem = UIBarButtonItem(
                title: "重建 Tab",
                style: .plain,
                target: self,
                action: #selector(debugRebuildSelectedTab)
            )
            navigationItem.rightBarButtonItems = (navigationItem.rightBarButtonItems ?? []) + [rebuildItem]
        }
#endif

        // 普通 Playground Tab 直接读取构建同步到 Bundles 根目录的当前 Bundle，
        // 这样调试按钮验收的就是最新前端产物；OTA v3 故障车道仍显式走 Manifest/current。
        let identity = otaV3FixtureEnabled
            ? (lynxAppId: "10000001", bundleName: "pages/10000001/bundle-050.lynx.bundle")
            : nil
        if otaV3FixtureEnabled && identity == nil {
            presentShellAlert(
                title: "Tab Bundle 不可用",
                message: "embedded Manifest 没有找到 main.lynx.bundle 的 App ID"
            )
            return
        }
        let tabAppId = identity?.lynxAppId
        let tabBundleName = identity?.bundleName

        let home = LynxTabViewController(
            spec: LynxTabSpec(
                tabId: "home",
                bundleURL: otaV3FixtureEnabled
                    ? identity?.bundleName ?? ""
                    : "assets://bundles/main.lynx.bundle",
                title: otaV3FixtureEnabled ? "首页（OTA v3）" : "首页",
                routeKey: "native-tab-home",
                initialData: ["source": "native-tab-demo"],
                globalProps: [
                    "queryItems": ["native_tab_id": "home"],
                ],
                lynxAppId: tabAppId,
                bundleName: tabBundleName
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
                    ? identity?.bundleName ?? ""
                    : "assets://bundles/main.lynx.bundle",
                title: otaV3FixtureEnabled ? "设置（OTA v3）" : "设置",
                routeKey: "native-tab-settings",
                initialData: ["source": "native-tab-demo"],
                globalProps: [
                    "queryItems": ["native_tab_id": "settings"],
                ],
                lynxAppId: tabAppId,
                bundleName: tabBundleName
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

    /** Demo 合成身份入口，业务宿主应由登录系统调用同一个 Router API。 */
    @objc private func selectOtaUser() {
        let sheet = UIAlertController(title: "OTA 测试用户", message: "注册后自动检查，Tab 只读取已提交版本", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "用户 A（灰度）", style: .default) { _ in
            _ = LynxRouter.registerOtaUserId("user_demo_A")
        })
        sheet.addAction(UIAlertAction(title: "用户 B（普通）", style: .default) { _ in
            _ = LynxRouter.registerOtaUserId("user_demo_B")
        })
        sheet.addAction(UIAlertAction(title: "退出登录（匿名）", style: .default) { _ in
            _ = LynxRouter.clearOtaUserId()
        })
        sheet.addAction(UIAlertAction(title: "独立打开测试 Bundle", style: .default) { [weak self] _ in
            do {
                _ = try LynxRouter.open(lynxAppId: "10000001", bundleName: "pages/10000001/bundle-050.lynx.bundle",
                                       options: ["title": "灰度独立页面", "fullscreen": false, "showNavigationBar": true])
            } catch {
                self?.presentShellAlert(title: "打开失败", message: error.localizedDescription)
            }
        })
        sheet.addAction(UIAlertAction(title: "查看 Bundle 磁盘", style: .default) { [weak self] _ in
            self?.openStorageInspector()
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = sheet.popoverPresentationController { popover.sourceView = view; popover.sourceRect = CGRect(x: view.bounds.midX, y: 0, width: 1, height: 1) }
        present(sheet, animated: true)
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
            // 只有宿主完成一次可用的 OTA 同步后才重读 Tab；没有 runtime 或同步失败时，
            // 保留当前 LynxView，避免“刷新失败”反而替换用户正在看的页面。
            if success {
                tabControllers.forEach { $0.refreshFromCurrent() }
            }
            refreshItem?.isEnabled = true
            presentShellAlert(
                title: success ? "OTA 同步完成" : "OTA 同步失败",
                message: success
                    ? "Tab 已重新读取当前已提交 Bundle"
                    : "已重读本地已提交版本，部分 App 同步失败，请检查 OTA 配置和网络"
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
