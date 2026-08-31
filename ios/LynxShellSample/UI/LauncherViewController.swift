import LynxShellKit
import UIKit

/**
 * iOS 原生壳首页。
 *
 * 默认冷启动由 SceneDelegate 直接进入本地 Playground；本控制器作为宿主页锚点和
 * Native Page Stack / OTA 诊断入口继续保留。若宿主没有提供安全配置，则展示真实
 * “未配置”错误，不伪造下载、清理或回滚成功。
 */
final class LauncherViewController: UIViewController {
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
#if DEBUG
    private var debugF12StatusLabel: UILabel?
    private var debugF12StatusTimer: Timer?
#endif

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        configureUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Android Sample 使用 NoActionBar；iOS 原生首页也隐藏 NavigationBar，让标题由内容承载。
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    private func configureUI() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 0
        scrollView.addSubview(contentStack)
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStack.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: 24
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -24
            ),
            contentStack.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor,
                constant: 24
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -32
            ),
            contentStack.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor,
                constant: -48
            ),
        ])

        let titleLabel = makeLabel(
            text: "Lynx Router 原生壳",
            style: .largeTitle,
            weight: .bold
        )
        titleLabel.accessibilityTraits = .header
        contentStack.addArrangedSubview(titleLabel)

        let introLabel = makeLabel(
            text: "默认进入 OTA 验收首页；Playground 首页和原生 Tab Demo 也可从这里打开。",
            style: .body
        )
        introLabel.textColor = .secondaryLabel
        contentStack.setCustomSpacing(8, after: titleLabel)
        contentStack.addArrangedSubview(introLabel)

        let otaHomeButton = makeButton(
            title: "打开 OTA 验收首页",
            filled: true,
            action: #selector(openOtaAcceptanceHome)
        )
        contentStack.setCustomSpacing(28, after: introLabel)
        contentStack.addArrangedSubview(otaHomeButton)

#if DEBUG
        if ProcessInfo.processInfo.environment["LYNX_TEST_PAUSE_AFTER_ROLLBACK_COMMIT"] == "1" {
            let prepareRollbackButton = makeButton(
                title: "准备 F12 回滚进程测试",
                filled: false,
                action: #selector(prepareRollbackProcessTest)
            )
            contentStack.setCustomSpacing(8, after: otaHomeButton)
            contentStack.addArrangedSubview(prepareRollbackButton)
            installDebugF12StatusLabel()
        }
#endif

        let playgroundButton = makeButton(
            title: "打开 Playground 首页",
            filled: false,
            action: #selector(openPlaygroundHome)
        )
        contentStack.setCustomSpacing(12, after: otaHomeButton)
        contentStack.addArrangedSubview(playgroundButton)

        let nativeTabButton = makeButton(
            title: "打开原生 Tab 承载 Demo",
            filled: false,
            action: #selector(openNativeTabDemo)
        )
        contentStack.setCustomSpacing(12, after: playgroundButton)
        contentStack.addArrangedSubview(nativeTabButton)

        let storageInspectorButton = makeButton(
            title: "查看 OTA 磁盘目录",
            filled: false,
            action: #selector(openOtaStorageInspector)
        )
        storageInspectorButton.accessibilityIdentifier = "open-ota-storage-inspector"
        contentStack.setCustomSpacing(12, after: nativeTabButton)
        contentStack.addArrangedSubview(storageInspectorButton)

        let embeddedButton = makeButton(
            title: "打开 Manifest 中的第一个内置 Bundle",
            filled: false,
            action: #selector(openEmbeddedDemo)
        )
        contentStack.setCustomSpacing(12, after: storageInspectorButton)
        contentStack.addArrangedSubview(embeddedButton)

        let card = makeOtaCard()
        contentStack.setCustomSpacing(16, after: embeddedButton)
        contentStack.addArrangedSubview(card)
    }

    private func makeOtaCard() -> UIView {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 2
        card.layer.borderColor = UIColor.systemBlue.cgColor

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 0
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
        ])

        let titleLabel = makeLabel(text: "OTA 验收入口", style: .title2, weight: .bold)
        titleLabel.accessibilityTraits = .header
        stack.addArrangedSubview(titleLabel)

        let routeLabel = makeLabel(
            text: "全量 latest-bundle-list → 按返回的 App ID 存储 → 本地 SHA 校验",
            style: .subheadline
        )
        routeLabel.textColor = .secondaryLabel
        stack.setCustomSpacing(8, after: titleLabel)
        stack.addArrangedSubview(routeLabel)

        let statusLabel = makeLabel(
            text: LynxRouter.isOtaInstalled
                ? "当前状态：iOS Router 内置 OTA SDK 已接入"
                : "当前状态：宿主尚未提供 OTA 服务地址和 clientToken",
            style: .footnote,
            weight: .semibold
        )
        statusLabel.textColor = .systemOrange
        stack.setCustomSpacing(12, after: routeLabel)
        stack.addArrangedSubview(statusLabel)

        let openButton = makeButton(
            title: "打开 OTA 验收首页",
            filled: true,
            action: #selector(openOtaAcceptanceHome)
        )
        stack.setCustomSpacing(20, after: statusLabel)
        stack.addArrangedSubview(openButton)

#if DEBUG
        let fixtureButton = makeButton(
            title: "打开当前 OTA v3 Bundle-050",
            filled: false,
            action: #selector(openOtaV3FixtureBundle)
        )
        fixtureButton.accessibilityIdentifier = "open-ota-v3-fixture-bundle"
        stack.setCustomSpacing(12, after: openButton)
        stack.addArrangedSubview(fixtureButton)
#endif

        let deleteButton = makeButton(
            title: "删除全部 OTA Bundle",
            filled: false,
            action: #selector(deleteAllOtaBundles)
        )
        stack.setCustomSpacing(12, after: openButton)
        stack.addArrangedSubview(deleteButton)

        let noteLabel = makeLabel(
            text: "删除只影响本地 OTA 下载内容，不会删除 App 内置资源，也不会生成隐藏备份目录。",
            style: .footnote
        )
        noteLabel.textColor = .secondaryLabel
        stack.setCustomSpacing(12, after: deleteButton)
        stack.addArrangedSubview(noteLabel)
        return card
    }

    private func makeLabel(
        text: String,
        style: UIFont.TextStyle,
        weight: UIFont.Weight = .regular
    ) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        label.font = UIFontMetrics(forTextStyle: style).scaledFont(
            for: .systemFont(ofSize: UIFont.preferredFont(forTextStyle: style).pointSize, weight: weight)
        )
        return label
    }

    private func makeButton(
        title: String,
        filled: Bool,
        action: Selector
    ) -> UIButton {
        // 使用 iOS 13 可用的传统 UIButton API，不抬高 Module 最低部署版本。
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.layer.cornerRadius = 12
        button.layer.cornerCurve = .continuous
        button.layer.borderWidth = filled ? 0 : 1.5
        button.layer.borderColor = UIColor.systemBlue.cgColor
        if filled {
            button.backgroundColor = .systemBlue
            button.setTitleColor(.white, for: .normal)
        } else {
            button.backgroundColor = .clear
            button.setTitleColor(.systemBlue, for: .normal)
        }
        button.addTarget(self, action: action, for: .touchUpInside)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: filled ? 56 : 52).isActive = true
        return button
    }

    @objc private func openEmbeddedDemo() {
        do {
            _ = try LynxRouter.openFirstEmbedded(
                params: ["source": "ios-embedded-manifest-demo"],
                options: ["title": "内置 Bundle Demo"]
            )
        } catch {
            presentShellAlert(title: "无法打开内置 Bundle", message: error.localizedDescription)
        }
    }

    @objc private func openPlaygroundHome() {
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
            presentShellAlert(
                title: "无法打开 Playground 首页",
                message: error.localizedDescription
            )
        }
    }

    @objc private func openOtaAcceptanceHome() {
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
            presentShellAlert(
                title: "无法打开 OTA 验收首页",
                message: error.localizedDescription
            )
        }
    }

#if DEBUG
    /** 直接验证当前 v3 CAS release 的真实 Bundle；页面内容自带 V1/V2 标识。 */
    @objc private func openOtaV3FixtureBundle() {
        do {
            _ = try LynxRouter.open(
                lynxAppId: "10000001",
                bundleName: "pages/10000001/bundle-050.lynx.bundle",
                params: ["source": "ios-ota-store-v3-fixture"],
                options: [
                    "title": "OTA v3 Bundle-050",
                    "fullscreen": false,
                    "showNavigationBar": true,
                ]
            )
        } catch {
            presentShellAlert(
                title: "无法打开 OTA v3 Fixture",
                message: error.localizedDescription
            )
        }
    }
#endif

    @objc private func openNativeTabDemo() {
        navigationController?.pushViewController(
            NativeTabBarDemoViewController(),
            animated: true
        )
    }

    @objc private func openOtaStorageInspector() {
        navigationController?.pushViewController(
            OtaStorageInspectorViewController(),
            animated: true
        )
    }

#if DEBUG
    @objc private func prepareRollbackProcessTest() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await LynxRouter.debugPrepareRollbackProcessTest()
            let success = result == "ok"
            self.presentShellAlert(
                title: success ? "F12 准备完成" : "F12 准备失败",
                message: success
                    ? "已准备 canonical downloaded current/previous，可开始首屏回滚进程中断测试"
                    : "准备失败：\(result)"
            )
        }
    }

    private func installDebugF12StatusLabel() {
        let label = makeLabel(text: "F12 status: idle", style: .caption1)
        label.accessibilityIdentifier = "lynx-debug-f12-status"
        label.textColor = .systemOrange
        contentStack.addArrangedSubview(label)
        debugF12StatusLabel = label
        updateDebugF12Status()
        debugF12StatusTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateDebugF12Status()
        }
    }

    private func updateDebugF12Status() {
        debugF12StatusLabel?.text = "F12 status: \(LynxRouter.debugF12Status)"
        debugF12StatusLabel?.accessibilityValue = LynxRouter.debugF12Status
    }
#endif

    @objc private func deleteAllOtaBundles() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await LynxRouter.deleteAllOtaBundles()
                self.presentShellAlert(title: "删除完成", message: "已删除全部 OTA 下载 Bundle")
            } catch {
                self.presentShellAlert(title: "删除失败", message: error.localizedDescription)
            }
        }
    }

#if DEBUG
    deinit {
        debugF12StatusTimer?.invalidate()
    }
#endif
}

/** Demo-only 原生只读 OTA Store 浏览器。 */
final class OtaStorageInspectorViewController: UIViewController {
    private let textView = UITextView()
    private var loadTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "OTA 磁盘浏览器"
        view.backgroundColor = .systemGroupedBackground
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .systemGroupedBackground
        textView.textColor = .label
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 28, right: 16)
        textView.accessibilityIdentifier = "ota-storage-inspector-content"
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "刷新",
            style: .plain,
            target: self,
            action: #selector(refreshSnapshot)
        )
        loadSnapshot()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: false)
    }

    deinit {
        loadTask?.cancel()
    }

    @objc private func refreshSnapshot() {
        loadSnapshot()
    }

    private func loadSnapshot() {
        loadTask?.cancel()
        navigationItem.rightBarButtonItem?.isEnabled = false
        textView.text = "正在读取一致性快照…\n\n只读操作，不会触发 OTA 请求或修改文件。"
        loadTask = Task { [weak self] in
            let result: Result<OtaStorageSnapshot?, Error>
            do {
                result = .success(try await LynxRouter.otaStorageSnapshot())
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.navigationItem.rightBarButtonItem?.isEnabled = true
                switch result {
                case let .success(snapshot):
                    self.textView.text = snapshot.map(Self.render) ?? "当前没有远程 OTA Store。"
                case let .failure(error):
                    self.textView.text = "OTA 磁盘快照读取失败\n\n\(error.localizedDescription)"
                }
            }
        }
    }

    private static func render(_ snapshot: OtaStorageSnapshot) -> String {
        var lines: [String] = [
            "OTA 磁盘浏览器",
            "",
            "root: \(snapshot.rootPath)",
            "apps: \(snapshot.apps.count)",
            "files: \(snapshot.fileCount)",
            "disk: \(formatBytes(snapshot.totalBytes))",
            "mode: 只读",
        ]
        if snapshot.apps.isEmpty {
            lines += ["", "当前没有远程 OTA Bundle；页面将使用 App Bundle baseline。"]
            return lines.joined(separator: "\n")
        }
        for app in snapshot.apps {
            lines += [
                "",
                "━━━━━━━━━━━━━━━━━━━━━━━━",
                "App ID  \(app.appId)",
                "current: \(app.state?.currentReleaseId ?? "—") (\(app.state?.currentKind ?? "none"))",
                "previous: \(app.state?.previousReleaseId ?? "—")",
                "candidate: \(app.candidate?.releaseId ?? "—")" + (app.candidate.map { " (\($0.status))" } ?? ""),
                "disk: \(formatBytes(app.totalBytes)) / \(app.fileCount) files",
                "CAS objects: \(app.objectCount) / \(formatBytes(app.objectBytes))",
                "manifests: \(formatBytes(app.manifestBytes))",
            ]
            for release in app.releases {
                let roles = release.roles.map(roleLabel).sorted().joined(separator: " · ")
                lines += [
                    "",
                    "\(release.releaseId) [\(roles)]",
                    "manifest: \(release.manifestValid ? "valid" : "invalid")",
                    "size: \(formatBytes(release.totalBytes)) / \(release.fileCount) files",
                ]
                lines += release.files.map { "├─ \($0.relativePath)  \(formatBytes($0.byteCount))" }
                if release.truncated { lines.append("└─ …文件列表已截断") }
            }
            if !app.staging.isEmpty {
                lines += ["", "未完成的 staging"]
                for staging in app.staging {
                    lines.append("\(staging.transactionName)  \(formatBytes(staging.totalBytes))")
                    lines += staging.files.map { "├─ \($0.relativePath)  \(formatBytes($0.byteCount))" }
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func roleLabel(_ role: OtaStorageReleaseRole) -> String {
        switch role {
        case .current: return "当前"
        case .previous: return "上一个"
        case .candidate: return "候选"
        case .leased: return "页面使用中"
        case .orphan: return "孤儿"
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        guard bytes >= 1024 else { return "\(bytes) B" }
        let units = ["KB", "MB", "GB"]
        var value = Double(bytes)
        var index = -1
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return String(format: "%.1f %@", value, units[index])
    }
}
