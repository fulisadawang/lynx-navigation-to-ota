import LynxShellKit
import UIKit

/**
 * iOS 原生壳首页。
 *
 * 默认启动只展示 Native Page Stack 验收入口，不再自动进入 main.lynx.bundle，也不保留
 * URL/initData/globalProps 调试表单。按钮直接调用 LynxRouter 的真实 OTA open/delete API；
 * 若宿主没有提供安全配置，则展示真实“未配置”错误，不伪造下载、清理或回滚成功。
 */
final class LauncherViewController: UIViewController {
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

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
            text: "当前首页只验收 Native Page Stack OTA，不再进入旧的 main.lynx.bundle。",
            style: .body
        )
        introLabel.textColor = .secondaryLabel
        contentStack.setCustomSpacing(8, after: titleLabel)
        contentStack.addArrangedSubview(introLabel)

        let card = makeOtaCard()
        contentStack.setCustomSpacing(28, after: introLabel)
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
            text: "10000001 / home.lynx.bundle\nCI/CD → OSS → latest-bundle-list → 本地 SHA 校验",
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
            action: #selector(openOtaPage)
        )
        stack.setCustomSpacing(20, after: statusLabel)
        stack.addArrangedSubview(openButton)

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

    @objc private func openOtaPage() {
        do {
            _ = try LynxRouter.open(
                lynxAppId: "10000001",
                bundleName: "home.lynx.bundle",
                params: ["source": "ios-shell-ota-demo"],
                options: ["title": "OTA Home"]
            )
        } catch {
            presentShellAlert(title: "无法打开 OTA 页面", message: error.localizedDescription)
        }
    }

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
}
