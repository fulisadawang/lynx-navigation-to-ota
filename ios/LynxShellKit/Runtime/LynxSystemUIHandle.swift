import UIKit
import Lynx

/** 中性的容器状态；Shell 不依赖具体能力 Pod。 */
final class ShellSystemUIState {
    var statusBarHidden: Bool?
    var statusBarStyle: UIStatusBarStyle?
    var homeIndicatorHidden: Bool?
    var orientationMask: UIInterfaceOrientationMask?
}

protocol ShellSystemUIOwner: AnyObject {
    var lynxSystemUIState: ShellSystemUIState { get }
    var lynxSystemUIView: LynxView? { get }
}

/** 只控制指定活体 View 的容器；宿主 adapter 不能借用别的页面或全局 Window。 */
public final class LynxSystemUIHandle {
    private weak var sourceView: LynxView?
    private weak var owner: (UIViewController & ShellSystemUIOwner)?
    private let originalHidden: Bool?
    private let originalStyle: UIStatusBarStyle?
    private let originalHomeIndicator: Bool?
    private let originalOrientation: UIInterfaceOrientationMask?
    private var orientationTask: Task<Void, Never>?
    private var orientationCompletion: ((Result<[String: Any], Error>) -> Void)?
    private var orientationRequestID: UUID?
    public private(set) var orientationRestoreError: Error?

    init(view: LynxView, owner: UIViewController & ShellSystemUIOwner) {
        sourceView = view
        self.owner = owner
        originalHidden = owner.lynxSystemUIState.statusBarHidden
        originalStyle = owner.lynxSystemUIState.statusBarStyle
        originalHomeIndicator = owner.lynxSystemUIState.homeIndicatorHidden
        originalOrientation = owner.lynxSystemUIState.orientationMask
    }

    private func currentOwner() -> (UIViewController & ShellSystemUIOwner)? {
        precondition(Thread.isMainThread, "系统 UI 操作必须在主线程执行")
        guard let owner, let sourceView, owner.lynxSystemUIView === sourceView,
              ShellMessageHub.pageId(for: sourceView) != nil, sourceView.window != nil else { return nil }
        return owner
    }

    public var isAvailable: Bool { currentOwner() != nil }

    public var statusBarInfo: [String: Any] {
        guard let owner = currentOwner() else { return ["available": false] }
        let style = owner.preferredStatusBarStyle == .lightContent ? "LIGHT" : "DARK"
        return ["visible": !owner.prefersStatusBarHidden, "style": style, "available": true]
    }

    @discardableResult public func setStatusBarVisible(_ visible: Bool) -> Bool {
        guard let owner = currentOwner() else { return false }
        owner.lynxSystemUIState.statusBarHidden = !visible
        owner.setNeedsStatusBarAppearanceUpdate()
        return true
    }

    public func setSystemBarsStyle(_ value: String) -> Bool {
        guard let owner = currentOwner() else { return false }
        let style: UIStatusBarStyle?
        switch value.uppercased() {
        case "DEFAULT": style = nil
        case "LIGHT": style = .lightContent
        case "DARK": style = .darkContent
        default: return false
        }
        owner.lynxSystemUIState.statusBarStyle = style
        owner.setNeedsStatusBarAppearanceUpdate()
        return true
    }

    public func setSystemBarsVisible(_ visible: Bool, type: String = "all") -> Bool {
        guard let owner = currentOwner() else { return false }
        switch type.lowercased() {
        case "status", "statusbar":
            owner.lynxSystemUIState.statusBarHidden = !visible
        case "navigation", "navigationbar":
            owner.lynxSystemUIState.homeIndicatorHidden = !visible
        case "all", "system", "systembars":
            owner.lynxSystemUIState.statusBarHidden = !visible
            owner.lynxSystemUIState.homeIndicatorHidden = !visible
        default: return false
        }
        owner.setNeedsStatusBarAppearanceUpdate()
        owner.setNeedsUpdateOfHomeIndicatorAutoHidden()
        return true
    }

    public func setOrientation(_ value: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let mask: UIInterfaceOrientationMask
        switch value.lowercased() {
        case "any": mask = .allButUpsideDown
        case "portrait", "portrait-primary": mask = .portrait
        case "portrait-secondary": mask = .portraitUpsideDown
        case "landscape": mask = .landscape
        case "landscape-primary": mask = .landscapeLeft
        case "landscape-secondary": mask = .landscapeRight
        default:
            completion(.failure(NSError(domain: "LynxSystemUI", code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "方向参数无效"])))
            return
        }
        requestOrientation(mask: mask, requested: value, completion: completion)
    }

    public func clearOrientation(completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let owner = currentOwner() else {
            completion(.failure(NSError(domain: "LynxSystemUI", code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "页面已失效"])))
            return
        }
        guard orientationCompletion == nil else {
            completion(.failure(NSError(domain: "LynxSystemUI", code: 1006,
                userInfo: [NSLocalizedDescriptionKey: "方向请求正在执行"])))
            return
        }
        let priorMask = owner.lynxSystemUIState.orientationMask
        owner.lynxSystemUIState.orientationMask = originalOrientation
        let supported = owner.supportedInterfaceOrientations
        owner.lynxSystemUIState.orientationMask = priorMask
        requestOrientation(mask: supported, requested: "any", unlocking: true) { result in
            completion(result.map { data in
                var value = data
                value["unlocked"] = true
                return value
            })
        }
    }

    private func requestOrientation(mask: UIInterfaceOrientationMask, requested: String, unlocking: Bool = false,
                                    completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let owner = currentOwner() else {
            completion(.failure(NSError(domain: "LynxSystemUI", code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "页面已失效"])))
            return
        }
        guard orientationCompletion == nil else {
            completion(.failure(NSError(domain: "LynxSystemUI", code: 1006,
                userInfo: [NSLocalizedDescriptionKey: "方向请求正在执行"])))
            return
        }
        let priorMask = owner.lynxSystemUIState.orientationMask
        let requestID = UUID()
        orientationRequestID = requestID
        orientationCompletion = completion
        owner.lynxSystemUIState.orientationMask = unlocking ? originalOrientation : mask
        if #available(iOS 16.0, *) {
            owner.setNeedsUpdateOfSupportedInterfaceOrientations()
            owner.view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, self.orientationRequestID == requestID else { return }
                    self.owner?.lynxSystemUIState.orientationMask = priorMask
                    if #available(iOS 16.0, *) { self.owner?.setNeedsUpdateOfSupportedInterfaceOrientations() }
                    self.finishOrientation(.failure(error))
                }
            }
        } else {
            UIViewController.attemptRotationToDeviceOrientation()
        }
        // UIKit 没有 geometry success 回调；以实际 Scene 方向为证据，2 秒上限只约束系统请求。
        orientationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<100 {
                guard !Task.isCancelled, self.orientationRequestID == requestID else { return }
                guard let owner = self.currentOwner(),
                      let actual = owner.view.window?.windowScene?.interfaceOrientation else {
                    self.finishOrientation(.failure(NSError(domain: "LynxSystemUI", code: 1002,
                        userInfo: [NSLocalizedDescriptionKey: "页面已失效"])))
                    return
                }
                let actualMask: UIInterfaceOrientationMask
                let type: String
                switch actual {
                case .portrait: actualMask = .portrait; type = "portrait-primary"
                case .portraitUpsideDown: actualMask = .portraitUpsideDown; type = "portrait-secondary"
                case .landscapeLeft: actualMask = .landscapeLeft; type = "landscape-primary"
                case .landscapeRight: actualMask = .landscapeRight; type = "landscape-secondary"
                default: actualMask = []; type = "unknown"
                }
                if !actualMask.isEmpty, mask.contains(actualMask) {
                    self.finishOrientation(.success(["orientation": requested, "requested": requested,
                        "type": type, "applied": true]))
                    return
                }
                do { try await Task.sleep(nanoseconds: 20_000_000) }
                catch { return }
            }
            self.owner?.lynxSystemUIState.orientationMask = priorMask
            if #available(iOS 16.0, *) { self.owner?.setNeedsUpdateOfSupportedInterfaceOrientations() }
            self.finishOrientation(.failure(NSError(domain: "LynxSystemUI", code: 1500,
                userInfo: [NSLocalizedDescriptionKey: "UIKit 未在系统请求期限内应用方向"])))
        }
    }

    private func finishOrientation(_ result: Result<[String: Any], Error>) {
        let callback = orientationCompletion
        orientationCompletion = nil
        orientationRequestID = nil
        orientationTask?.cancel()
        orientationTask = nil
        callback?(result)
    }

    public func setKeyboardStyle(_ value: String) -> Bool {
        guard let sourceView, currentOwner() != nil else { return false }
        let appearance: UIKeyboardAppearance
        switch value.uppercased() {
        case "DEFAULT": appearance = .default
        case "LIGHT": appearance = .light
        case "DARK": appearance = .dark
        default: return false
        }
        func apply(_ view: UIView) -> Bool {
            if let field = view as? UITextField, field.isFirstResponder {
                field.keyboardAppearance = appearance; field.reloadInputViews(); return true
            }
            if let field = view as? UITextView, field.isFirstResponder {
                field.keyboardAppearance = appearance; field.reloadInputViews(); return true
            }
            return view.subviews.contains { apply($0) }
        }
        return apply(sourceView)
    }

    /** SDK destroy 已可能注销 MessageHub；仍只恢复拥有原 View 的容器，不能覆盖新代次。 */
    public func restore() {
        precondition(Thread.isMainThread)
        finishOrientation(.failure(NSError(domain: "LynxSystemUI", code: 1002,
            userInfo: [NSLocalizedDescriptionKey: "能力 owner 已销毁"])))
        guard let owner, let sourceView, owner.lynxSystemUIView === sourceView else { return }
        owner.lynxSystemUIState.statusBarHidden = originalHidden
        owner.lynxSystemUIState.statusBarStyle = originalStyle
        owner.lynxSystemUIState.homeIndicatorHidden = originalHomeIndicator
        owner.lynxSystemUIState.orientationMask = originalOrientation
        owner.setNeedsStatusBarAppearanceUpdate()
        owner.setNeedsUpdateOfHomeIndicatorAutoHidden()
        if #available(iOS 16.0, *) {
            owner.setNeedsUpdateOfSupportedInterfaceOrientations()
            if let scene = sourceView.window?.windowScene {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: owner.supportedInterfaceOrientations)) { [weak self] error in
                    DispatchQueue.main.async { self?.orientationRestoreError = error }
                }
            }
        }
        else if sourceView.window != nil { UIViewController.attemptRotationToDeviceOrientation() }
    }
}

public extension LynxRouter {
    static func systemUIHandle(for sourceView: LynxView) -> LynxSystemUIHandle? {
        precondition(Thread.isMainThread)
        guard ShellMessageHub.pageId(for: sourceView) != nil else { return nil }
        var responder: UIResponder? = sourceView
        while let current = responder {
            if let owner = current as? (UIViewController & ShellSystemUIOwner), owner.lynxSystemUIView === sourceView {
                return LynxSystemUIHandle(view: sourceView, owner: owner)
            }
            responder = current.next
        }
        return nil
    }
}
