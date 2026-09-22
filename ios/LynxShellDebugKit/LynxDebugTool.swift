#if DEBUG
import Foundation
import UIKit
import Lynx
import LynxShellKit

public final class LynxDebugTool {
    public static let shared = LynxDebugTool()
    public let store: LynxDebugStore

    private var installed = false
    private weak var inspector: UINavigationController?
    private var presentationDelegate: LynxDebugPresentationDelegate?

    private init() {
        store = LynxDebugStore()
    }

    public static func install() {
        precondition(Thread.isMainThread, "LynxDebugTool.install 必须在主线程调用")
        shared.installIfNeeded()
    }

    /** 每个 UIWindowScene 调用一次；安装 App 内全局、可拖动的 Lynx 调试入口。 */
    public static func attach(to windowScene: UIWindowScene) {
        precondition(Thread.isMainThread, "LynxDebugTool.attach 必须在主线程调用")
        shared.installIfNeeded()
        LynxDebugFloatingOverlayManager.shared.attach(to: windowScene)
    }

    public static func present(from presenter: UIViewController) {
        precondition(Thread.isMainThread, "LynxDebugTool.present 必须在主线程调用")
        shared.installIfNeeded()
        guard shared.inspector == nil else {
            return
        }

        let host = presenter.navigationController?.visibleViewController ?? presenter

        let panel = LynxDebugPanelViewController(store: shared.store)
        let navigation = UINavigationController(rootViewController: panel)
        navigation.modalPresentationStyle = .pageSheet
        navigation.isModalInPresentation = true
        if #available(iOS 15.0, *) {
            let sheet = navigation.sheetPresentationController
            sheet?.detents = [.large()]
            sheet?.selectedDetentIdentifier = .large
            sheet?.prefersGrabberVisible = false
            sheet?.prefersScrollingExpandsWhenScrolledToEdge = false
        }

        let cleanup = { [weak navigation] in
            if shared.inspector === navigation {
                shared.inspector = nil
                shared.presentationDelegate = nil
            }
            LynxDebugFloatingOverlayManager.shared.setEntryHidden(false)
        }
        let delegate = LynxDebugPresentationDelegate(onDismiss: cleanup)
        shared.presentationDelegate = delegate
        shared.inspector = navigation
        panel.onClose = { [weak navigation] in
            guard let navigation else {
                cleanup()
                return
            }
            navigation.dismiss(animated: true)
        }
        panel.onDidDismiss = cleanup
        host.present(navigation, animated: true) {
            navigation.presentationController?.delegate = delegate
            LynxDebugFloatingOverlayManager.shared.setEntryHidden(true)
            if #available(iOS 15.0, *) {
                navigation.sheetPresentationController?.selectedDetentIdentifier = .large
            }
        }
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        // 官方 DevTool 开关由 Shell bootstrap 管理，面板安装不覆盖用户的持久化选择。
        LynxDebugBridge.install(store)
        LynxDebugInstallHttpCapture(
            { [weak store] request, streaming in
                guard let store, let url = request.url, !url.isEmpty else { return nil }
                return store.beginNetwork(
                    method: request.httpMethod ?? "GET",
                    url: url,
                    headers: request.httpHeaders ?? [:],
                    body: request.httpBody,
                    isStreaming: streaming,
                    viewId: store.networkAssociationViewId()
                )
            },
            { [weak store] identifier, _, response in
                let error = response.statusCode == 499 ? response.statusText : nil
                store?.finishNetwork(
                    id: identifier,
                    statusCode: response.statusCode,
                    error: error
                )
            }
        )
        LynxDebugFloatingOverlayManager.shared.install()
    }
}

private final class LynxDebugPresentationDelegate: NSObject, UIAdaptivePresentationControllerDelegate {
    private let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        false
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        onDismiss()
    }
}

private final class LynxDebugPanelViewController: UIViewController {
    private enum Tab: CaseIterable {
        case console, network, props, methods

        var title: String {
            switch self {
            case .console: return "Console"
            case .network: return "Network"
            case .props: return "Props"
            case .methods: return "Methods"
            }
        }
    }

    private let store: LynxDebugStore
    private let pageButton = LynxDebugActionButton()
    private let tabStack = UIStackView()
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private var tabButtons: [Tab: UIButton] = [:]
    private var selectedTab = Tab.console
    private var selectedViewId: String?
    private var listenerId: UUID?
    private var reportedDismissal = false
    private var copyToast: UIView?
    private var copyToastDismissWorkItem: DispatchWorkItem?
    private let accent = UIColor(red: 0.0, green: 0.404, blue: 0.882, alpha: 1)
    private let panelBackground = UIColor.systemGroupedBackground
    private let cardBackground = UIColor.systemBackground
    private let border = UIColor.separator.withAlphaComponent(0.35)
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var onClose: (() -> Void)?
    var onDidDismiss: (() -> Void)?

    init(store: LynxDebugStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("LynxDebugPanelViewController 只支持代码初始化")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = panelBackground
        navigationController?.setNavigationBarHidden(true, animated: false)
        buildHeader()
        buildPageSelector()
        buildTabs()
        buildContent()
        refreshPageSelector()
        refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        listenerId = store.addListener { [weak self] in
            guard let self else { return }
            self.refreshPageSelector()
            self.refresh()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let listenerId {
            store.removeListener(listenerId)
            self.listenerId = nil
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard !reportedDismissal,
              isBeingDismissed || navigationController?.isBeingDismissed == true else {
            return
        }
        reportedDismissal = true
        onDidDismiss?()
    }

    deinit {
        copyToastDismissWorkItem?.cancel()
        if let listenerId {
            store.removeListener(listenerId)
        }
    }

    private func buildHeader() {
        let header = UIView()
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        let handle = UIView()
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.backgroundColor = .tertiaryLabel
        handle.layer.cornerRadius = 2
        header.addSubview(handle)

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = "Lynx Debug Tool"
        title.font = .systemFont(ofSize: 18, weight: .bold)
        title.textColor = .label
        title.adjustsFontForContentSizeCategory = true
        header.addSubview(title)

        let close = makeToolbarButton(title: "×") { [weak self] in
            self?.onClose?()
        }
        header.addSubview(close)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            header.heightAnchor.constraint(equalToConstant: 52),
            handle.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            handle.topAnchor.constraint(equalTo: header.topAnchor),
            handle.widthAnchor.constraint(equalToConstant: 40),
            handle.heightAnchor.constraint(equalToConstant: 4),
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: 4),
            close.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: 4),
            close.widthAnchor.constraint(equalToConstant: 38),
            close.heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    private func buildPageSelector() {
        let label = makeLabel("当前页面", style: .caption1, color: .secondaryLabel)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        pageButton.translatesAutoresizingMaskIntoConstraints = false
        pageButton.addAction { [weak self] in self?.showPageChooser() }
        pageButton.contentHorizontalAlignment = .left
        pageButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        pageButton.titleLabel?.adjustsFontForContentSizeCategory = true
        pageButton.titleLabel?.lineBreakMode = .byTruncatingTail
        pageButton.setTitleColor(.label, for: .normal)
        pageButton.backgroundColor = cardBackground
        pageButton.layer.cornerRadius = 10
        pageButton.layer.cornerCurve = .continuous
        pageButton.layer.borderWidth = 1
        pageButton.layer.borderColor = border.cgColor
        pageButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        view.addSubview(pageButton)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 66),
            pageButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            pageButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            pageButton.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
            pageButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
    }

    private func buildTabs() {
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        tabStack.axis = .horizontal
        tabStack.spacing = 4
        tabStack.distribution = .fillEqually
        view.addSubview(tabStack)

        Tab.allCases.forEach { tab in
            let button = LynxDebugActionButton()
            button.addAction { [weak self] in
                self?.selectedTab = tab
                self?.refresh()
            }
            button.setTitle(tab.title, for: .normal)
            button.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.layer.cornerRadius = 9
            button.layer.cornerCurve = .continuous
            button.contentEdgeInsets = UIEdgeInsets(top: 9, left: 4, bottom: 9, right: 4)
            tabButtons[tab] = button
            tabStack.addArrangedSubview(button)
        }

        NSLayoutConstraint.activate([
            tabStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            tabStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            tabStack.topAnchor.constraint(equalTo: pageButton.bottomAnchor, constant: 10),
            tabStack.heightAnchor.constraint(equalToConstant: 38),
        ])
    }

    private func buildContent() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = true
        view.addSubview(scrollView)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 0
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: tabStack.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -16),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32),
        ])
    }

    private func refreshPageSelector() {
        let options = store.pageOptions()
        let selected = options.first { $0.viewId == selectedViewId }
        if selected == nil, selectedViewId != nil {
            selectedViewId = nil
        }
        pageButton.setTitle("\(selected?.label ?? "全部页面")  ›", for: .normal)
    }

    private func showPageChooser() {
        let options: [(String?, String)] = [(nil, "全部页面")] + store.pageOptions().map { ($0.viewId, $0.label) }
        let alert = UIAlertController(title: "选择页面", message: nil, preferredStyle: .alert)
        options.forEach { id, label in
            let action = UIAlertAction(title: label, style: .default) { [weak self] _ in
                self?.selectedViewId = id
                self?.refreshPageSelector()
                self?.refresh()
            }
            if id == selectedViewId {
                action.setValue(accent, forKey: "titleTextColor")
            }
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func refresh() {
        tabButtons.forEach { tab, button in
            let selected = tab == selectedTab
            button.setTitleColor(selected ? accent : .secondaryLabel, for: .normal)
            button.backgroundColor = selected ? accent.withAlphaComponent(0.12) : .clear
        }

        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        switch selectedTab {
        case .console: renderConsole()
        case .network: renderNetwork()
        case .props: renderProps()
        case .methods: renderMethods()
        }
    }

    private func renderConsole() {
        addTabAction("清空 Console") { [weak self] in
            self?.store.clearConsole(viewId: self?.selectedViewId)
            self?.refresh()
        }
        let logs = store.console(for: selectedViewId).reversed()
        guard !logs.isEmpty else {
            addEmpty("当前页面暂无 Console 日志\n\niOS Console 数据源尚未接入 LynxShellDebugKit。")
            return
        }
        logs.forEach { log in
            addCard(copyText: "\(log.tag)\n\(log.message)") { stack in
                addText(to: stack, "\(timeFormatter.string(from: Date(timeIntervalSince1970: Double(log.timestampMs) / 1000)))  \(log.type.uppercased())", font: .systemFont(ofSize: 13, weight: .semibold), color: statusColor(log.type))
                if !log.tag.isEmpty {
                    addText(to: stack, log.tag, font: .preferredFont(forTextStyle: .caption1), color: .secondaryLabel)
                }
                addText(to: stack, log.message, font: .preferredFont(forTextStyle: .subheadline), color: .label)
            }
        }
    }

    private func renderNetwork() {
        addTabAction("清空 Network") { [weak self] in
            self?.store.clearNetwork(viewId: self?.selectedViewId)
            self?.refresh()
        }
        let requests = store.network(for: selectedViewId).reversed()
        guard !requests.isEmpty else {
            addEmpty("当前页面暂无 Lynx HTTP 请求\n\n多页面场景中无法可靠关联的请求，请切换到“全部页面”。")
            return
        }
        requests.forEach { request in
            let status = request.statusCode.map(String.init) ?? (request.error == nil ? "pending" : "ERR")
            let elapsed = request.endTimeMs.map { "\($0 - request.startTimeMs)ms" } ?? "running"
            let duration = request.isStreaming && request.endTimeMs != nil ? "TTFB \(elapsed)" : elapsed
            addCard(copyText: request.curl) { stack in
                let kind = request.isStreaming ? "STREAM \(request.method)" : request.method
                let httpError = request.statusCode.map { $0 >= 400 } ?? false
                let color: UIColor = request.error != nil || httpError
                    ? .systemRed
                    : (request.endTimeMs == nil ? accent : .systemGreen)
                addText(to: stack, "\(kind)  \(status)  \(duration)", font: .systemFont(ofSize: 13, weight: .semibold), color: color)
                addText(to: stack, DebugRedactor.url(request.url), font: .preferredFont(forTextStyle: .subheadline), color: .label)
                let owner = request.viewId.map { String($0.prefix(8)) } ?? "unassigned"
                addText(to: stack, "LynxHttpService · view=\(owner)", font: .preferredFont(forTextStyle: .caption1), color: .secondaryLabel)
                addText(to: stack, "cURL", font: .systemFont(ofSize: 13, weight: .semibold), color: accent)
                addText(to: stack, request.curl, font: .monospacedSystemFont(ofSize: 12, weight: .regular), color: .secondaryLabel)
            }
        }
    }

    private func renderProps() {
        let snapshots = store.containers(for: selectedViewId)
        guard !snapshots.isEmpty else {
            addEmpty("当前页面暂无 GlobalProps")
            return
        }
        snapshots.forEach { snapshot in
            addCard(copyText: jsonString(snapshot.globalProps)) { stack in
                addText(to: stack, "\(snapshot.containerKind) · \(snapshot.routeKey)", font: .systemFont(ofSize: 13, weight: .semibold), color: .label)
                addText(to: stack, "页面路径  \(snapshot.routeKey)", font: .preferredFont(forTextStyle: .caption1), color: .secondaryLabel)
                addText(to: stack, "Bundle  \(DebugRedactor.url(snapshot.bundleURL))", font: .preferredFont(forTextStyle: .caption1), color: .secondaryLabel)
                addText(to: stack, "viewId  \(snapshot.viewId)", font: .preferredFont(forTextStyle: .caption1), color: .tertiaryLabel)
                addSection(to: stack, title: "GlobalProps", values: snapshot.globalProps)
            }
        }
    }

    private func renderMethods() {
        let methods = store.methods(for: selectedViewId).reversed()
        guard !methods.isEmpty else {
            addEmpty("当前页面暂无 Native Method 调用\n\n只显示本项目已注册的 NativeModules；没有伪造 Sparkling 方法。")
            return
        }
        methods.forEach { method in
            let success = method.success != false
            let status = method.endTimeMs == nil ? "running" : (success ? "OK" : "ERR")
            let duration = method.endTimeMs.map { "\($0 - method.startTimeMs)ms" } ?? "running"
            let view = method.viewId.map { String($0.prefix(8)) } ?? "unknown"
            addCard(copyText: "\(method.name)\n\(method.params)\n\(method.result ?? "")") { stack in
                addText(to: stack, "\(status)  \(method.name)", font: .systemFont(ofSize: 13, weight: .semibold), color: success ? .systemGreen : .systemRed)
                addText(to: stack, "code=\(method.code.map(String.init) ?? "-") · \(duration) · view=\(view)", font: .preferredFont(forTextStyle: .caption1), color: .secondaryLabel)
                addSection(to: stack, title: "params", values: ["value": method.params.isEmpty ? "(empty)" : method.params])
                addSection(to: stack, title: "result", values: ["value": method.result ?? "(pending)"])
            }
        }
    }

    private func addEmpty(_ text: String) {
        let label = makeLabel(text, style: .subheadline, color: .secondaryLabel)
        label.numberOfLines = 0
        label.textAlignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(label)
        contentStack.setCustomSpacing(24, after: label)
    }

    private func addTabAction(_ title: String, action: @escaping () -> Void) {
        let button = LynxDebugActionButton()
        button.addAction(action)
        button.setTitle(title, for: .normal)
        button.setTitleColor(accent, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        button.backgroundColor = accent.withAlphaComponent(0.10)
        button.layer.cornerRadius = 9
        button.layer.cornerCurve = .continuous
        button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        button.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(button)
        button.widthAnchor.constraint(lessThanOrEqualTo: contentStack.widthAnchor).isActive = true
        contentStack.setCustomSpacing(8, after: button)
    }

    private func addCard(copyText: String, builder: (UIStackView) -> Void) {
        let card = UIView()
        card.backgroundColor = cardBackground
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = border.cgColor

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 4
        card.addSubview(stack)

        let copy = LynxDebugActionButton()
        copy.addAction { [weak self, weak copy] in
            guard let copy else { return }
            self?.copy(copyText, source: copy)
        }
        copy.setTitle("复制", for: .normal)
        copy.setTitleColor(accent, for: .normal)
        copy.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        copy.backgroundColor = accent.withAlphaComponent(0.10)
        copy.layer.cornerRadius = 8
        copy.contentEdgeInsets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        copy.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(copy)
        copy.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        copy.setContentHuggingPriority(.required, for: .horizontal)
        copy.setContentCompressionResistancePriority(.required, for: .horizontal)

        builder(stack)
        contentStack.addArrangedSubview(card)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])
        contentStack.setCustomSpacing(8, after: card)
    }

    private func addSection(to stack: UIStackView, title: String, values: [String: Any]) {
        addText(to: stack, title, font: .systemFont(ofSize: 13, weight: .semibold), color: accent)
        values.keys.sorted().forEach { key in
            let row = UIStackView()
            row.axis = .horizontal
            row.alignment = .top
            row.spacing = 8
            let keyLabel = makeLabel(key, style: .caption1, color: .secondaryLabel)
            let valueLabel = makeLabel(formatValue(values[key]), style: .caption1, color: .label)
            valueLabel.numberOfLines = 4
            row.addArrangedSubview(keyLabel)
            row.addArrangedSubview(valueLabel)
            keyLabel.widthAnchor.constraint(equalToConstant: 92).isActive = true
            stack.addArrangedSubview(row)
        }
    }

    private func addText(to stack: UIStackView, _ text: String, font: UIFont, color: UIColor) {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        stack.addArrangedSubview(label)
    }

    private func makeToolbarButton(title: String, action: @escaping () -> Void) -> UIButton {
        let button = LynxDebugActionButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addAction(action)
        button.setTitle(title, for: .normal)
        button.setTitleColor(accent, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        button.backgroundColor = accent.withAlphaComponent(0.10)
        button.layer.cornerRadius = 10
        button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        return button
    }

    private func makeLabel(_ text: String, style: UIFont.TextStyle, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.textColor = color
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    private func copy(_ text: String, source: UIButton) {
        UIPasteboard.general.string = text

        source.isUserInteractionEnabled = false
        source.setTitle("已复制 ✓", for: .normal)
        source.setTitleColor(.systemGreen, for: .normal)
        source.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.12)

        let feedback = UINotificationFeedbackGenerator()
        feedback.notificationOccurred(.success)
        showCopyToast()
        UIAccessibility.post(notification: .announcement, argument: "已复制")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self, weak source] in
            guard let self, let source else { return }
            source.setTitle("复制", for: .normal)
            source.setTitleColor(self.accent, for: .normal)
            source.backgroundColor = self.accent.withAlphaComponent(0.10)
            source.isUserInteractionEnabled = true
        }
    }

    private func showCopyToast() {
        copyToastDismissWorkItem?.cancel()
        copyToast?.removeFromSuperview()

        let toast = LynxDebugToastView(text: "已复制到剪贴板")
        toast.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toast)
        copyToast = toast
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            toast.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            toast.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])

        toast.alpha = 0
        if UIAccessibility.isReduceMotionEnabled {
            toast.alpha = 1
        } else {
            toast.transform = CGAffineTransform(translationX: 0, y: 8)
            UIView.animate(
                withDuration: 0.18,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState]
            ) {
                toast.alpha = 1
                toast.transform = .identity
            }
        }

        let dismiss = DispatchWorkItem { [weak self, weak toast] in
            guard let self, let toast else { return }
            let remove = {
                toast.removeFromSuperview()
                if self.copyToast === toast {
                    self.copyToast = nil
                }
            }
            if UIAccessibility.isReduceMotionEnabled {
                remove()
            } else {
                UIView.animate(
                    withDuration: 0.16,
                    delay: 0,
                    options: [.curveEaseIn, .beginFromCurrentState],
                    animations: { toast.alpha = 0 },
                    completion: { _ in remove() }
                )
            }
        }
        copyToastDismissWorkItem = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: dismiss)
    }

    private func formatValue(_ value: Any?) -> String {
        guard let value else { return "null" }
        if let string = value as? String { return string.replacingOccurrences(of: "\n", with: " ").prefix(1000).description }
        if let dictionary = value as? [String: Any] {
            return "Object(\(dictionary.count))  \(jsonString(dictionary).prefix(600))"
        }
        if let array = value as? [Any] {
            return "Array(\(array.count))  \(jsonString(array).prefix(600))"
        }
        if value is NSNull { return "null" }
        return String(describing: value).replacingOccurrences(of: "\n", with: " ").prefix(1000).description
    }

    private func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return text
    }

    private func statusColor(_ type: String) -> UIColor {
        switch type.lowercased() {
        case "error": return .systemRed
        case "warn": return .systemOrange
        default: return .label
        }
    }
}

private final class LynxDebugActionButton: UIButton {
    private var handler: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    func addAction(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc private func handleTap() {
        handler?()
    }

    override var isHighlighted: Bool {
        didSet {
            alpha = isHighlighted ? 0.62 : 1
        }
    }
}

private final class LynxDebugToastView: UIView {
    init(text: String) {
        super.init(frame: .zero)

        backgroundColor = UIColor.label.withAlphaComponent(0.92)
        isUserInteractionEnabled = false
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .systemBackground
        label.adjustsFontForContentSizeCategory = true
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("LynxDebugToastView 只支持代码初始化")
    }
}

private enum DebugRedactor {
    private static let sensitive = try! NSRegularExpression(pattern: "(?i)(token|secret|password|passwd|authorization|cookie|accesskey|session)")

    static func url(_ value: String) -> String {
        guard var components = URLComponents(string: value) else {
            return value.split(separator: "?").first.map(String.init) ?? value
        }
        components.query = nil
        components.fragment = nil
        return components.string ?? value
    }
}
#endif
