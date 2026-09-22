#if DEBUG
import UIKit

/** App 内、按 UIWindowScene 存活的全局调试入口；窗口只拦截悬浮按钮自身的触摸。 */
final class LynxDebugFloatingOverlayManager {
    static let shared = LynxDebugFloatingOverlayManager()

    private struct Overlay {
        let window: LynxDebugPassthroughWindow
        let controller: LynxDebugFloatingRootViewController
    }

    private var overlays: [String: Overlay] = [:]
    private var observerTokens: [NSObjectProtocol] = []
    private var installed = false
    private var entryHidden = false

    private init() {}

    func install() {
        precondition(Thread.isMainThread, "LynxDebugFloatingOverlayManager 必须在主线程安装")
        guard !installed else { return }
        installed = true

        observerTokens = [
            NotificationCenter.default.addObserver(
                forName: UIScene.didActivateNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let scene = notification.object as? UIWindowScene else { return }
                self?.attach(to: scene)
            },
            NotificationCenter.default.addObserver(
                forName: UIScene.didDisconnectNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let scene = notification.object as? UIWindowScene else { return }
                self?.detach(from: scene)
            },
        ]

        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState != .unattached }
            .forEach(attach(to:))
    }

    func attach(to scene: UIWindowScene) {
        precondition(Thread.isMainThread, "LynxDebugFloatingOverlayManager.attach 必须在主线程调用")
        let identifier = scene.session.persistentIdentifier
        guard overlays[identifier] == nil else { return }

        let controller = LynxDebugFloatingRootViewController { [weak self, weak scene] in
            guard let self, let scene else { return }
            self.openInspector(in: scene)
        }
        let window = LynxDebugPassthroughWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level.alert + 1
        window.backgroundColor = .clear
        window.rootViewController = controller
        window.isHidden = false
        controller.setEntryHidden(entryHidden)
        overlays[identifier] = Overlay(window: window, controller: controller)
    }

    func setEntryHidden(_ hidden: Bool) {
        precondition(Thread.isMainThread, "Lynx Debug 悬浮入口状态必须在主线程更新")
        entryHidden = hidden
        overlays.values.forEach { $0.controller.setEntryHidden(hidden) }
    }

    private func detach(from scene: UIWindowScene) {
        let identifier = scene.session.persistentIdentifier
        guard let overlay = overlays.removeValue(forKey: identifier) else { return }
        overlay.window.isHidden = true
        overlay.window.rootViewController = nil
    }

    private func openInspector(in scene: UIWindowScene) {
        guard let presenter = topPresenter(in: scene) else { return }
        LynxDebugTool.present(from: presenter)
    }

    private func topPresenter(in scene: UIWindowScene) -> UIViewController? {
        let overlayWindows = Set(overlays.values.map { ObjectIdentifier($0.window) })
        let hostWindow = scene.windows.first {
            $0.isKeyWindow && !overlayWindows.contains(ObjectIdentifier($0))
        } ?? scene.windows.first {
            !$0.isHidden && !overlayWindows.contains(ObjectIdentifier($0))
        }
        guard let root = hostWindow?.rootViewController else { return nil }
        return topController(root)
    }

    private func topController(_ controller: UIViewController) -> UIViewController {
        if let presented = controller.presentedViewController, !presented.isBeingDismissed {
            return topController(presented)
        }
        if let navigation = controller as? UINavigationController,
           let visible = navigation.visibleViewController {
            return topController(visible)
        }
        if let tab = controller as? UITabBarController,
           let selected = tab.selectedViewController {
            return topController(selected)
        }
        return controller
    }
}

private final class LynxDebugPassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        guard hit !== rootViewController?.view else { return nil }
        return hit
    }
}

private final class LynxDebugFloatingRootViewController: UIViewController {
    private let floatingView: LynxDebugFloatingView
    private let defaults = UserDefaults.standard
    private let xKey = "lynx.debug.floating.normalized_x"
    private let yKey = "lynx.debug.floating.normalized_y"
    private var positioned = false

    init(onActivate: @escaping () -> Void) {
        floatingView = LynxDebugFloatingView(onActivate: onActivate)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("LynxDebugFloatingRootViewController 只支持代码初始化")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.addSubview(floatingView)
        floatingView.onPositionChanged = { [weak self] center, finished in
            guard let self else { return center }
            let clamped = self.clamped(center: center)
            if finished {
                let snapped = self.snapped(center: clamped)
                self.persist(center: snapped)
                return snapped
            }
            return clamped
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }
        floatingView.bounds = CGRect(origin: .zero, size: CGSize(width: 68, height: 44))
        if !positioned {
            floatingView.center = restoredCenter()
            positioned = true
        } else {
            floatingView.center = clamped(center: floatingView.center)
        }
    }

    func setEntryHidden(_ hidden: Bool) {
        floatingView.isHidden = hidden
        floatingView.isUserInteractionEnabled = !hidden
    }

    private func restoredCenter() -> CGPoint {
        let minCenter = minimumCenter
        let maxCenter = maximumCenter
        let storedX = defaults.object(forKey: xKey) as? Double
        let storedY = defaults.object(forKey: yKey) as? Double
        let normalizedX = CGFloat(storedX ?? 1)
        let normalizedY = CGFloat(storedY ?? 0.66)
        return CGPoint(
            x: minCenter.x + (maxCenter.x - minCenter.x) * normalizedX.clamped(to: 0 ... 1),
            y: minCenter.y + (maxCenter.y - minCenter.y) * normalizedY.clamped(to: 0 ... 1)
        )
    }

    private func persist(center: CGPoint) {
        let minCenter = minimumCenter
        let maxCenter = maximumCenter
        let width = max(maxCenter.x - minCenter.x, 1)
        let height = max(maxCenter.y - minCenter.y, 1)
        defaults.set(Double((center.x - minCenter.x) / width), forKey: xKey)
        defaults.set(Double((center.y - minCenter.y) / height), forKey: yKey)
    }

    private func clamped(center: CGPoint) -> CGPoint {
        CGPoint(
            x: center.x.clamped(to: minimumCenter.x ... maximumCenter.x),
            y: center.y.clamped(to: minimumCenter.y ... maximumCenter.y)
        )
    }

    private func snapped(center: CGPoint) -> CGPoint {
        let targetX = center.x < view.bounds.midX ? minimumCenter.x : maximumCenter.x
        return CGPoint(x: targetX, y: center.y)
    }

    private var minimumCenter: CGPoint {
        CGPoint(
            x: view.safeAreaInsets.left + floatingView.bounds.width / 2 + 12,
            y: view.safeAreaInsets.top + floatingView.bounds.height / 2 + 12
        )
    }

    private var maximumCenter: CGPoint {
        CGPoint(
            x: view.bounds.width - view.safeAreaInsets.right - floatingView.bounds.width / 2 - 12,
            y: view.bounds.height - view.safeAreaInsets.bottom - floatingView.bounds.height / 2 - 12
        )
    }
}

private final class LynxDebugFloatingView: UIView {
    private let onActivate: () -> Void
    private let materialView: UIVisualEffectView
    private var dragStart = CGPoint.zero
    var onPositionChanged: ((CGPoint, Bool) -> CGPoint)?

    init(onActivate: @escaping () -> Void) {
        self.onActivate = onActivate
        if UIAccessibility.isReduceTransparencyEnabled {
            materialView = UIVisualEffectView(effect: nil)
        } else {
            materialView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        }
        super.init(frame: .zero)

        isAccessibilityElement = true
        accessibilityLabel = "打开 Lynx 调试面板"
        accessibilityTraits = .button
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 4)

        materialView.frame = bounds
        materialView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        materialView.isUserInteractionEnabled = false
        materialView.backgroundColor = UIAccessibility.isReduceTransparencyEnabled
            ? UIColor.systemBackground
            : UIColor.systemBlue.withAlphaComponent(0.14)
        materialView.layer.cornerRadius = 18
        materialView.layer.cornerCurve = .continuous
        materialView.layer.masksToBounds = true
        materialView.layer.borderWidth = 1
        materialView.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.28).cgColor
        addSubview(materialView)

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Lynx"
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .systemBlue
        label.adjustsFontForContentSizeCategory = true
        label.isUserInteractionEnabled = false
        materialView.contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: materialView.contentView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: materialView.contentView.centerYAnchor),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        tap.require(toFail: pan)
        addGestureRecognizer(tap)
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) {
        fatalError("LynxDebugFloatingView 只支持代码初始化")
    }

    override func accessibilityActivate() -> Bool {
        onActivate()
        return true
    }

    @objc private func handleTap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onActivate()
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let host = superview else { return }
        switch recognizer.state {
        case .began:
            if let presentationPosition = layer.presentation()?.position {
                layer.removeAllAnimations()
                center = presentationPosition
            }
            dragStart = center
            UIView.animate(withDuration: 0.12) {
                self.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
            }
        case .changed:
            let translation = recognizer.translation(in: host)
            let proposed = CGPoint(x: dragStart.x + translation.x, y: dragStart.y + translation.y)
            center = onPositionChanged?(proposed, false) ?? proposed
        case .ended, .cancelled:
            let target = onPositionChanged?(center, true) ?? center
            guard !UIAccessibility.isReduceMotionEnabled else {
                center = target
                transform = .identity
                return
            }
            UIViewPropertyAnimator(duration: 0.32, dampingRatio: 1) {
                self.center = target
                self.transform = .identity
            }.startAnimation()
        default:
            break
        }
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
#endif
