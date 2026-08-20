import Lynx
import UIKit

/** 一次原生导航操作的稳定结果；data 用于栈状态、entry 标识或页面结果。 */
struct LynxNavigationResult {
    let code: Int
    let message: String
    let affectedCount: Int
    let data: [String: Any]

    var isSuccess: Bool { code == 0 }
}

/** `open` 的页面复用策略，wireName 与 Android/TypeScript 完全一致。 */
enum ShellLaunchMode: String, CaseIterable {
    case push
    case singleTop
    case clearTop
    case singleTask

    static func parse(_ value: String) throws -> ShellLaunchMode {
        guard let mode = allCases.first(where: {
            $0.rawValue.caseInsensitiveCompare(value) == .orderedSame
        }) else {
            throw LynxRouteError.invalidArgument(
                "launchMode 只支持 push、singleTop、clearTop、singleTask"
            )
        }
        return mode
    }
}

/**
 * 一次导航命令的通用选项。
 *
 * 页面展示字段继续由 LynxRouteParser 解析；这里仅处理 launch mode、动画、防重复和
 * 返回结果。两类字段可以共存于同一个 optionsJSON。
 */
struct ShellNavigationOptions {
    let launchMode: ShellLaunchMode
    let animated: Bool
    let deduplicate: Bool
    let deduplicateWindowMilliseconds: Int
    let result: [String: Any]?
    /** 当前 open 的原生转场声明。 */
    let transitionSpec: ShellTransitionSpec
    /** prepareRoute 返回的一次性 Bundle 字节 token。 */
    let preparedRouteToken: String?

    init(
        launchMode: ShellLaunchMode = .push,
        animated: Bool = true,
        deduplicate: Bool = true,
        deduplicateWindowMilliseconds: Int = 350,
        result: [String: Any]? = nil,
        transitionSpec: ShellTransitionSpec? = nil,
        preparedRouteToken: String? = nil
    ) {
        self.launchMode = launchMode
        self.animated = animated
        self.deduplicate = deduplicate
        self.deduplicateWindowMilliseconds = deduplicateWindowMilliseconds
        self.result = result
        self.transitionSpec = transitionSpec ?? (animated ? .default : .withoutAnimation)
        self.preparedRouteToken = preparedRouteToken
    }

    static func fromJSON(_ json: String) throws -> ShellNavigationOptions {
        let value = try decodeObject(json.isEmpty ? "{}" : json, field: "options")
        let window = number(value["deduplicateWindowMs"])?.intValue ?? 350
        guard (0...5_000).contains(window) else {
            throw LynxRouteError.invalidArgument(
                "deduplicateWindowMs 必须在 0...5000 之间"
            )
        }
        let animated = bool(value["animated"]) ?? true
        return ShellNavigationOptions(
            launchMode: try ShellLaunchMode.parse(
                string(value["launchMode"]) ?? ShellLaunchMode.push.rawValue
            ),
            animated: animated,
            deduplicate: bool(value["deduplicate"]) ?? true,
            deduplicateWindowMilliseconds: window,
            result: try optionalObject(value["result"], field: "result"),
            transitionSpec: try ShellTransitionSpec.parse(
                options: value,
                animated: animated
            ),
            preparedRouteToken: string(value["preparedRouteToken"]).flatMap {
                let normalized = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return normalized.isEmpty ? nil : normalized
            }
        )
    }

    static func withResultJSON(_ json: String) throws -> ShellNavigationOptions {
        ShellNavigationOptions(
            result: try decodeObject(json, field: "navigation result")
        )
    }

    private static func decodeObject(_ json: String, field: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else {
            throw LynxRouteError.invalidJSON(field)
        }
        return object
    }

    private static func optionalObject(
        _ value: Any?,
        field: String
    ) throws -> [String: Any]? {
        guard let value, !(value is NSNull) else { return nil }
        if let object = value as? [String: Any] { return object }
        if let json = value as? String { return try decodeObject(json, field: field) }
        throw LynxRouteError.invalidJSON(field)
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        guard let value, !(value is NSNull) else { return nil }
        return String(describing: value)
    }

    private static func number(_ value: Any?) -> NSNumber? {
        if let value = value as? NSNumber { return value }
        if let value = value as? String, let number = Double(value) {
            return NSNumber(value: number)
        }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            if ["1", "true", "yes"].contains(value.lowercased()) { return true }
            if ["0", "false", "no"].contains(value.lowercased()) { return false }
        }
        return nil
    }
}

/**
 * 业务 App 的主页接入点。
 *
 * 通用壳不知道真实 UITabBarController，业务宿主应在 Scene/Coordinator 启动时注入，
 * 并在 handler 中选择目标 Tab、恢复对应 UINavigationController 根页面。
 */
typealias ShellAppHomeHandler = (
    _ navigationController: UINavigationController,
    _ options: [String: Any]
) -> Bool

/**
 * App 内唯一 Lynx 页面导航器；Native Module 与业务入口共同复用。
 *
 * `routeKey` 定位逻辑页面，`sessionID` 隔离一次 Lynx 会话，`entryID` 唯一标识页面实例，
 * `order` 用于恢复原顺序。closeAll 会移除当前 session 及其后的原生/Lynx 页面，
 * 保留进入 Lynx 前的 UINavigationController 前缀。
 */
final class ShellNavigator: NSObject, UIAdaptivePresentationControllerDelegate {
    static let shared = ShellNavigator()

    private weak var navigationController: UINavigationController?
    private var appHomeHandler: ShellAppHomeHandler?
    private let transitionCoordinator = ShellTransitionCoordinator()
    /** nav.delegate 是 weak，必须由导航器强持有组合代理。 */
    private var navigationDelegateMux: ShellNavigationDelegateMux?
    private weak var systemSheetController: LynxContainerViewController?
    /** iOS 15+ Sheet 内仍用真实 UINavigationController 承载后续 entry。 */
    private var systemSheetNavigationController: UINavigationController?
    private var systemSheetNavigationDelegateMux: ShellNavigationDelegateMux?
    private var lastOperationKey = ""
    private var busyUntilMilliseconds = -Double.greatestFiniteMagnitude

    private let snapshotKey = "lynx_shell.navigation.snapshot.v1"
    private let resultKeyPrefix = "lynx_shell.navigation.result."

    private override init() {
        super.init()
    }

    /** 绑定业务 App 实际使用的 UINavigationController。 */
    func attach(_ navigationController: UINavigationController) {
        self.navigationController = navigationController
        transitionCoordinator.install(on: navigationController)
        if let mux = navigationDelegateMux, navigationController.delegate === mux {
            return
        }
        let mux = ShellNavigationDelegateMux(
            transitionCoordinator: transitionCoordinator,
            downstream: navigationController.delegate
        )
        navigationDelegateMux = mux
        navigationController.delegate = mux
    }

    /** 安装“返回 App 主 Tab”的业务实现；后续调用会替换旧 Handler。 */
    func installAppHomeHandler(_ handler: @escaping ShellAppHomeHandler) {
        appHomeHandler = handler
    }

    /** 兼容业务/Scene 旧调用；内部仍进入统一 options 实现。 */
    @discardableResult
    func open(_ request: LynxPageRequest, animated: Bool = true) -> LynxNavigationResult {
        open(request, options: ShellNavigationOptions(animated: animated))
    }

    /**
     * 打开一个 Lynx 页面。
     *
     * - push：始终新增；
     * - singleTop：栈顶同 routeKey 时原位刷新；
     * - clearTop：回到已有目标并保留旧参数；
     * - singleTask：回到已有目标并使用新参数刷新。
     */
    @discardableResult
    func open(
        _ request: LynxPageRequest,
        options: ShellNavigationOptions,
        sourceLynxView: LynxView? = nil
    ) -> LynxNavigationResult {
        guard let rootNavigationController = navigationController else {
            return failure(1002, "宿主导航器不可用")
        }
        let navigationController = operationNavigationController(
            root: rootNavigationController
        )
        activateTransitionCoordinator(on: navigationController)
        let request = request.withTransitionSpec(options.transitionSpec)
        let source = navigationController.topViewController as? LynxContainerViewController
        let operationScope = source?.navigationSessionID
            ?? "host:\(ObjectIdentifier(navigationController).hashValue)"
        let routeKey = request.resolvedRouteKey
        if let rejected = rejectOperation(
            key: "open:\(operationScope):\(options.launchMode.rawValue):\(routeKey)",
            options: options,
            navigationController: navigationController
        ) {
            return rejected
        }

        if let source {
            let stack = logicalSessionControllers(
                sessionID: source.navigationSessionID,
                root: rootNavigationController
            )
            let sessionControllers = stack
            let target = sessionControllers.last(where: { $0.routeKey == routeKey })

            switch options.launchMode {
            case .push:
                break

            case .singleTop:
                if source.routeKey == routeKey {
                    source.replaceRequest(request)
                    persistNavigationSnapshot()
                    return success(
                        "singleTop 已刷新栈顶页面",
                        affectedCount: 1,
                        data: entryData(source, launchMode: .singleTop)
                    )
                }

            case .clearTop:
                if let target,
                   let targetIndex = stack.firstIndex(where: { $0 === target }) {
                    if target.navigationController !== navigationController {
                        return clearSystemSheetToRootTarget(
                            target,
                            request: request,
                            launchMode: .clearTop,
                            options: options,
                            logicalStack: stack,
                            targetIndex: targetIndex,
                            root: rootNavigationController
                        )
                    }
                    let affectedCount = stack.count - targetIndex - 1
                    guard affectedCount > 0 else {
                        return success(
                            "clearTop 目标已在栈顶",
                            affectedCount: 0,
                            data: entryData(target, launchMode: .clearTop)
                        )
                    }
                    let removedEntries = stack.suffix(from: targetIndex + 1)
                        .map { $0 }
                    let ticket = transitionCoordinator.beginPop(
                        // clearTop 是本次 open 的一部分，必须冻结本次 options，
                        // 不能偷偷复用当前页上一次 push 时保存的转场配置。
                        spec: options.transitionSpec,
                        source: source,
                        target: target,
                        routeKey: target.routeKey,
                        forceCustomAnimator: true
                    )
                    let shouldAnimate = options.animated &&
                        options.transitionSpec.baseEffectiveStyle != .none &&
                        options.transitionSpec.durationMilliseconds(for: .pop) > 0
                    guard navigationController.popToViewController(
                        target,
                        animated: shouldAnimate
                    ) != nil else {
                        transitionCoordinator.failActiveTransition(
                            reason: "native_stack_update_failed"
                        )
                        return failure(1500, "clearTop 修改原生导航栈失败")
                    }
                    removedEntries.forEach {
                        removePendingResult(entryID: $0.navigationEntryID)
                    }
                    if !shouldAnimate {
                        transitionCoordinator.completeImmediatePop(target: target)
                    }
                    persistNavigationSnapshot()
                    var data = entryData(target, launchMode: .clearTop)
                    appendTransition(ticket, to: &data)
                    return success(
                        "clearTop 已回到 \(routeKey)",
                        affectedCount: affectedCount,
                        data: data
                    )
                }

            case .singleTask:
                if let target,
                   let targetIndex = stack.firstIndex(where: { $0 === target }) {
                    if target.navigationController !== navigationController {
                        return clearSystemSheetToRootTarget(
                            target,
                            request: request,
                            launchMode: .singleTask,
                            options: options,
                            logicalStack: stack,
                            targetIndex: targetIndex,
                            root: rootNavigationController
                        )
                    }
                    let affectedCount = stack.count - targetIndex - 1
                    guard affectedCount > 0 else {
                        target.replaceRequest(request)
                        persistNavigationSnapshot()
                        return success(
                            "singleTask 已刷新栈顶页面",
                            affectedCount: 1,
                            data: entryData(target, launchMode: .singleTask)
                        )
                    }
                    let removedEntries = stack.suffix(from: targetIndex + 1)
                        .map { $0 }
                    let ticket = transitionCoordinator.beginPop(
                        // singleTask 同样属于本次 open，转场必须使用调用方刚传入
                        // 的 options；target 刷新不会反向篡改已经冻结的事务。
                        spec: options.transitionSpec,
                        source: source,
                        target: target,
                        routeKey: routeKey,
                        forceCustomAnimator: true
                    )
                    target.replaceRequest(request)
                    let shouldAnimate = options.animated &&
                        options.transitionSpec.baseEffectiveStyle != .none &&
                        options.transitionSpec.durationMilliseconds(for: .pop) > 0
                    guard navigationController.popToViewController(
                        target,
                        animated: shouldAnimate
                    ) != nil else {
                        transitionCoordinator.failActiveTransition(
                            reason: "native_stack_update_failed"
                        )
                        return failure(1500, "singleTask 修改原生导航栈失败")
                    }
                    removedEntries.forEach {
                        removePendingResult(entryID: $0.navigationEntryID)
                    }
                    if !shouldAnimate {
                        transitionCoordinator.completeImmediatePop(target: target)
                    }
                    persistNavigationSnapshot()
                    var data = entryData(target, launchMode: .singleTask)
                    appendTransition(ticket, to: &data)
                    return success(
                        "singleTask 已复用并刷新 \(routeKey)",
                        affectedCount: affectedCount + 1,
                        data: data
                    )
                }
            }
        }

        let sessionID = source?.navigationSessionID ?? UUID().uuidString
        let sessionOrders = logicalSessionControllers(
            sessionID: sessionID,
            root: rootNavigationController
        ).map(\.navigationOrder)
        let order = (sessionOrders.max() ?? -1) + 1
        if #available(iOS 15.0, *),
           request.transitionSpec.routeType == .bottomSheet,
           systemSheetNavigationController != nil {
            return failure(1006, "当前 iOS Page Sheet 内不能再次嵌套 Sheet")
        }
        var preparedData: Data?
        var preparedReason: String?
        if let token = options.preparedRouteToken {
            switch ShellPreparedRouteStore.shared.consume(
                token: token,
                expectedURL: request.bundleURL
            ) {
            case let .success(data):
                preparedData = data
            case .failure:
                // 预取只是优化。token 失效时仍走普通 Provider，并通过状态说明降级。
                preparedReason = "prepared_route_expired"
            }
        }
        if request.transitionSpec.routeType == .bottomSheet {
            if #available(iOS 15.0, *) {
                return presentSystemBottomSheet(
                    request: request,
                    options: options,
                    source: source,
                    sessionID: sessionID,
                    order: order,
                    preparedData: preparedData,
                    additionalReason: preparedReason,
                    navigationController: rootNavigationController
                )
            }
        }
        let ticket = transitionCoordinator.beginPush(
            spec: request.transitionSpec,
            routeKey: routeKey,
            additionalReason: preparedReason
        )
        let requestWithTransition = request.withNativeTransition(ticket.metadata)
        let controller = LynxContainerViewController(
            request: requestWithTransition,
            navigationSessionID: sessionID,
            navigationEntryID: UUID().uuidString,
            navigationParentEntryID: source?.navigationEntryID,
            navigationOrder: order,
            preparedBundleData: preparedData
        )
        if request.transitionSpec.routeType == .heroSheet,
           let source,
           source.isViewLoaded,
           let sourceSnapshot = source.view.snapshotView(afterScreenUpdates: false) {
            // heroSheet 不再经过 ShellNavigationAnimator；透明目标 VC 仍需要一张固定的
            // 来源画面，否则 UIKit 在移除 fromView 后会把透明区域合成为黑色。
            controller.installTransitionBackdrop(sourceSnapshot)
        }
        transitionCoordinator.commitPush(
            target: controller,
            sourceLynxView: sourceLynxView,
            navigationController: navigationController
        ) { [weak self] in
            self?.persistNavigationSnapshot()
        }
        var data = entryData(controller, launchMode: options.launchMode)
        data["transactionID"] = ticket.transactionID
        data["requestedTransition"] = ticket.metadata.requestedTransition.rawValue
        data["effectiveTransition"] = ticket.metadata.effectiveTransition.rawValue
        data["status"] = ShellTransitionState.Status.accepted.rawValue
        if let reason = ticket.metadata.reason {
            data["reason"] = reason
        }
        return success(
            "页面打开事务已接受",
            data: data
        )
    }

    /** iOS 15+ 的 Sheet 直接交给 UIKit，不再进入自定义导航 animator。 */
    @available(iOS 15.0, *)
    private func presentSystemBottomSheet(
        request: LynxPageRequest,
        options: ShellNavigationOptions,
        source: LynxContainerViewController?,
        sessionID: String,
        order: Int,
        preparedData: Data?,
        additionalReason: String?,
        navigationController: UINavigationController
    ) -> LynxNavigationResult {
        guard navigationController.presentedViewController == nil else {
            return failure(1006, "当前已有原生模态页面")
        }
        let controller = LynxContainerViewController(
            request: request,
            navigationSessionID: sessionID,
            navigationEntryID: UUID().uuidString,
            navigationParentEntryID: source?.navigationEntryID,
            navigationOrder: order,
            preparedBundleData: preparedData,
            usesSystemSheetPresentation: true
        )
        let sheetNavigationController = UINavigationController(
            rootViewController: controller
        )
        sheetNavigationController.setNavigationBarHidden(true, animated: false)
        sheetNavigationController.modalPresentationStyle = .pageSheet
        sheetNavigationController.isModalInPresentation = !(
            request.transitionSpec.routeConfig.barrierDismissible ?? true
        )
        configureSystemSheet(
            sheetNavigationController,
            options: request.transitionSpec.routeOptions
        )
        sheetNavigationController.presentationController?.delegate = self
        systemSheetController = controller
        systemSheetNavigationController = sheetNavigationController
        navigationController.present(
            sheetNavigationController,
            animated: options.animated
        ) { [weak self, weak sheetNavigationController] in
            guard let self, let sheetNavigationController else { return }
            self.activateTransitionCoordinator(on: sheetNavigationController)
            self.transitionCoordinator.suspendBackGestureForSystemSheet()
            self.persistNavigationSnapshot()
        }
        // presentationController 可能在 present 调用中重新创建；展示提交后再绑定一次。
        sheetNavigationController.presentationController?.delegate = self
        var data: [String: Any] = [
            "entryID": controller.navigationEntryID,
            "routeKey": controller.routeKey,
            "launchMode": options.launchMode.rawValue,
            "presentation": "UISheetPresentationController",
            "routeType": request.transitionSpec.routeType?.rawValue
                ?? ShellRouteType.bottomSheet.rawValue,
            "status": ShellTransitionState.Status.accepted.rawValue,
        ]
        if let additionalReason {
            data["reason"] = additionalReason
        }
        return success("iOS 系统 Page Sheet 已提交", data: data)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard presentationController.presentedViewController ===
            systemSheetNavigationController else { return }
        finishSystemSheetDismissal()
    }

    /** 容器生命周期兜底：防止 UIKit 某些关闭路径未投递 adaptive delegate。 */
    func systemSheetDidDisappear(_ controller: LynxContainerViewController) {
        guard controller === systemSheetController else { return }
        DispatchQueue.main.async { [weak self, weak controller] in
            guard let self, let controller,
                  controller === self.systemSheetController,
                  self.systemSheetNavigationController?.presentingViewController == nil else {
                return
            }
            self.finishSystemSheetDismissal()
        }
    }

    /** 当前容器显示时切换系统返回手势与壳自定义 edge 手势。 */
    func updateBackGesture(for controller: LynxContainerViewController) {
        if let controllerNavigation = controller.navigationController {
            activateTransitionCoordinator(on: controllerNavigation)
        }
        if controller.usesSystemSheetPresentation {
            transitionCoordinator.suspendBackGestureForSystemSheet()
            return
        }
        transitionCoordinator.updateBackGesture(for: controller)
    }

    /** 显式壳转场期间导航栏显隐必须瞬时切换，避免叠加 UIKit chrome 动画。 */
    func allowsSystemChromeAnimation(for controller: LynxContainerViewController) -> Bool {
        transitionCoordinator.allowsSystemChromeAnimation(for: controller)
    }

    /** NativeModules 的业务 ready 信号。 */
    func markTransitionReady(_ transactionID: String) -> LynxNavigationResult {
        guard transitionCoordinator.markReady(transactionID: transactionID) else {
            return failure(1003, "转场事务不存在或已经结束")
        }
        return success(
            "转场业务内容已标记 ready",
            data: ["transactionID": transactionID]
        )
    }

    /** 返回最近一笔转场的低频诊断状态。 */
    func transitionState() -> LynxNavigationResult {
        success("转场状态读取成功", data: transitionCoordinator.currentState().dictionary)
    }

    /** Scene 进入后台时清理 snapshot/interaction，恢复只保留已提交页面栈。 */
    func cancelActiveTransitionForBackground() {
        transitionCoordinator.cancelForBackground()
    }

    /**
     * 保留旧契约：关闭当前容器。
     *
     * 与 back(delta) 不同，当前页是 session 首页时也允许 pop 到宿主页。
     */
    @discardableResult
    func close(animated: Bool = true) -> LynxNavigationResult {
        guard let rootNavigationController = navigationController else {
            return failure(1002, "宿主导航器不可用")
        }
        let navigationController = operationNavigationController(
            root: rootNavigationController
        )
        activateTransitionCoordinator(on: navigationController)
        if let sheet = systemSheetController,
           navigationController === systemSheetNavigationController,
           navigationController.topViewController === sheet,
           navigationController.viewControllers.count == 1 {
            let options = ShellNavigationOptions(animated: animated)
            if let rejected = rejectOperation(
                key: "close:\(sheet.navigationEntryID)",
                options: options,
                navigationController: navigationController
            ) {
                return rejected
            }
            dismissSystemSheet(animated: animated)
            return success(
                "当前 iOS 系统 Page Sheet 已关闭",
                affectedCount: 1,
                data: ["presentation": "UISheetPresentationController"]
            )
        }
        if navigationController === rootNavigationController,
           let presented = navigationController.presentedViewController {
            presented.dismiss(animated: true)
            return success("当前模态页面已关闭", affectedCount: 1)
        }
        guard let current = navigationController.topViewController as? LynxContainerViewController,
              navigationController.viewControllers.count > 1 else {
            return failure(1002, "当前页面不可关闭")
        }
        let options = ShellNavigationOptions(animated: animated)
        if let rejected = rejectOperation(
            key: "close:\(current.navigationEntryID)",
            options: options,
            navigationController: navigationController
        ) {
            return rejected
        }
        let spec = current.request.transitionSpec
        let target = navigationController.viewControllers[
            navigationController.viewControllers.count - 2
        ]
        let ticket = transitionCoordinator.beginPop(
            spec: spec,
            source: current,
            target: target,
            routeKey: (target as? LynxContainerViewController)?.routeKey ?? "host"
        )
        let shouldAnimate = options.animated &&
            spec.baseEffectiveStyle != .none &&
            spec.durationMilliseconds(for: .pop) > 0
        guard navigationController.popViewController(animated: shouldAnimate) != nil else {
            transitionCoordinator.failActiveTransition(reason: "native_stack_update_failed")
            return failure(1500, "关闭页面时修改原生导航栈失败")
        }
        removePendingResult(entryID: current.navigationEntryID)
        if !shouldAnimate {
            transitionCoordinator.completeImmediatePop(target: target)
        }
        persistNavigationSnapshot()
        var data: [String: Any] = [:]
        appendTransition(ticket, to: &data)
        return success("当前页面已关闭", affectedCount: 1, data: data)
    }

    /**
     * 在当前 Lynx session 内回退 delta 页。
     *
     * delta 超过可退深度时只回到 session 首页；options.result 绑定最终目标 entry。
     */
    @discardableResult
    func back(
        delta: Int,
        options: ShellNavigationOptions
    ) -> LynxNavigationResult {
        guard delta > 0 else { return failure(1001, "delta 必须大于 0") }
        guard let rootNavigationController = navigationController else {
            return failure(1002, "宿主导航器不可用")
        }
        let navigationController = operationNavigationController(
            root: rootNavigationController
        )
        activateTransitionCoordinator(on: navigationController)
        guard let current = navigationController.topViewController as?
            LynxContainerViewController else {
            return failure(1002, "当前页面不在 Lynx 导航会话中")
        }
        if let rejected = rejectOperation(
            key: "back:\(current.navigationEntryID):\(delta)",
            options: options,
            navigationController: navigationController
        ) {
            return rejected
        }
        let sessionControllers = logicalSessionControllers(
            sessionID: current.navigationSessionID,
            root: rootNavigationController
        )
        guard let currentIndex = sessionControllers.lastIndex(where: { $0 === current }),
              currentIndex > 0 else {
            if current === systemSheetController {
                if let result = options.result,
                   let target = previousRootSessionController(
                    before: current,
                    root: rootNavigationController
                   ) {
                    storeResult(
                        result,
                        from: current,
                        targetEntryID: target.navigationEntryID
                    )
                }
                dismissSystemSheet(animated: options.animated)
                return success(
                    "已关闭 iOS 系统 Page Sheet",
                    affectedCount: 1,
                    data: ["presentation": "UISheetPresentationController"]
                )
            }
            return failure(1005, "当前已是 Lynx session 首页")
        }
        let actualDelta = min(delta, currentIndex)
        let target = sessionControllers[currentIndex - actualDelta]
        let closing = Array(sessionControllers[(currentIndex - actualDelta + 1)...currentIndex])
        if target.navigationController !== navigationController {
            return popAcrossSystemSheet(
                source: current,
                target: target,
                closing: closing,
                requestedDelta: delta,
                actualDelta: actualDelta,
                options: options,
                root: rootNavigationController
            )
        }
        let spec = popTransitionSpec(from: current, options: options)
        let ticket = transitionCoordinator.beginPop(
            spec: spec,
            source: current,
            target: target,
            routeKey: target.routeKey
        )
        let shouldAnimate = options.animated &&
            spec.baseEffectiveStyle != .none &&
            spec.durationMilliseconds(for: .pop) > 0
        guard navigationController.popToViewController(
            target,
            animated: shouldAnimate
        ) != nil else {
            transitionCoordinator.failActiveTransition(reason: "native_stack_update_failed")
            return failure(1500, "back 修改原生导航栈失败")
        }
        if let result = options.result {
            storeResult(result, from: current, targetEntryID: target.navigationEntryID)
        }
        closing.forEach { removePendingResult(entryID: $0.navigationEntryID) }
        if !shouldAnimate {
            transitionCoordinator.completeImmediatePop(target: target)
        }
        persistNavigationSnapshot()
        var data: [String: Any] = [
            "requestedDelta": delta,
            "actualDelta": actualDelta,
            "targetRouteKey": target.routeKey,
            "targetEntryID": target.navigationEntryID,
        ]
        appendTransition(ticket, to: &data)
        return success(
            "已回退 \(actualDelta) 页",
            affectedCount: closing.count,
            data: data
        )
    }

    /** 兼容旧调用：使用默认选项回到当前 session 已存在的 routeKey。 */
    @discardableResult
    func popTo(routeKey: String) -> LynxNavigationResult {
        popTo(routeKey: routeKey, options: ShellNavigationOptions())
    }

    /** A-B-C-D-E 调用 popTo("A") 后回到已有 A；目标不存在时明确失败。 */
    @discardableResult
    func popTo(
        routeKey: String,
        options: ShellNavigationOptions
    ) -> LynxNavigationResult {
        guard let rootNavigationController = navigationController else {
            return failure(1002, "宿主导航器不可用")
        }
        let navigationController = operationNavigationController(
            root: rootNavigationController
        )
        activateTransitionCoordinator(on: navigationController)
        guard let current = navigationController.topViewController as?
            LynxContainerViewController else {
            return failure(1002, "当前页面不在 Lynx 导航会话中")
        }
        let normalizedKey = routeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { return failure(1001, "routeKey 不能为空") }
        if let rejected = rejectOperation(
            key: "popTo:\(current.navigationSessionID):\(normalizedKey)",
            options: options,
            navigationController: navigationController
        ) {
            return rejected
        }

        let stack = logicalSessionControllers(
            sessionID: current.navigationSessionID,
            root: rootNavigationController
        )
        guard let targetIndex = stack.lastIndex(where: { controller in
            controller.routeKey == normalizedKey
        }) else {
            return failure(1003, "当前 Lynx 会话中不存在 routeKey=\(normalizedKey)")
        }
        let target = stack[targetIndex]
        if target.navigationController !== navigationController {
            let closing = Array(stack.suffix(from: targetIndex + 1))
            return popAcrossSystemSheet(
                source: current,
                target: target,
                closing: closing,
                requestedDelta: closing.count,
                actualDelta: closing.count,
                options: options,
                root: rootNavigationController,
                popToRouteKey: normalizedKey
            )
        }
        let removedEntries = stack.suffix(from: targetIndex + 1)
            .map { $0 }
        let affectedCount = stack.count - targetIndex - 1
        guard affectedCount > 0 else {
            return success(
                "目标页面已在栈顶",
                affectedCount: 0,
                data: [
                    "targetEntryID": target.navigationEntryID,
                    "targetRouteKey": target.routeKey,
                ]
            )
        }
        let spec = popTransitionSpec(from: current, options: options)
        let ticket = transitionCoordinator.beginPop(
            spec: spec,
            source: current,
            target: target,
            routeKey: target.routeKey
        )
        let shouldAnimate = options.animated &&
            spec.baseEffectiveStyle != .none &&
            spec.durationMilliseconds(for: .pop) > 0
        guard navigationController.popToViewController(
            target,
            animated: shouldAnimate
        ) != nil else {
            transitionCoordinator.failActiveTransition(reason: "native_stack_update_failed")
            return failure(1500, "popTo 修改原生导航栈失败")
        }
        if let result = options.result {
            storeResult(result, from: current, targetEntryID: target.navigationEntryID)
        }
        removedEntries.forEach { removePendingResult(entryID: $0.navigationEntryID) }
        if !shouldAnimate {
            transitionCoordinator.completeImmediatePop(target: target)
        }
        persistNavigationSnapshot()
        var data: [String: Any] = [
            "targetEntryID": target.navigationEntryID,
            "targetRouteKey": target.routeKey,
        ]
        appendTransition(ticket, to: &data)
        return success(
            "已回退到 \(normalizedKey)",
            affectedCount: affectedCount,
            data: data
        )
    }

    /** 兼容旧调用：关闭当前 Lynx session，返回第一个 Lynx 页面之前的宿主控制器。 */
    @discardableResult
    func closeAll(animated: Bool = true) -> LynxNavigationResult {
        closeAll(options: ShellNavigationOptions(animated: animated))
    }

    /**
     * 关闭当前 session 以及它上方穿插的原生页面，保留进入 Lynx 前的控制器前缀。
     */
    @discardableResult
    func closeAll(options: ShellNavigationOptions) -> LynxNavigationResult {
        guard let rootNavigationController = navigationController else {
            return failure(1002, "宿主导航器不可用")
        }
        let navigationController = operationNavigationController(
            root: rootNavigationController
        )
        guard let current = navigationController.topViewController as?
            LynxContainerViewController else {
            return failure(1002, "当前页面不在 Lynx 导航会话中")
        }
        if let rejected = rejectOperation(
            key: "closeAll:\(current.navigationSessionID)",
            options: options,
            navigationController: navigationController
        ) {
            return rejected
        }
        if navigationController === systemSheetNavigationController {
            return closeSessionUnderSystemSheet(
                current.navigationSessionID,
                options: options,
                root: rootNavigationController
            )
        }
        return closeSession(
            current.navigationSessionID,
            in: rootNavigationController,
            options: options
        )
    }

    /**
     * 由宿主 Home Handler 选择应用主 Tab；接受后再确保当前 Lynx session 被清理。
     *
     * Handler 返回 false 时不主动修改当前栈，与 Android 保持一致。
     */
    @discardableResult
    func reLaunch(
        optionsJSON: String,
        navigationOptions: ShellNavigationOptions
    ) -> LynxNavigationResult {
        guard let rootNavigationController = navigationController else {
            return failure(1002, "宿主导航器不可用")
        }
        let operationNavigationController = operationNavigationController(
            root: rootNavigationController
        )
        guard let current = operationNavigationController.topViewController as?
            LynxContainerViewController else {
            return failure(1002, "当前页面不在 Lynx 导航会话中")
        }
        guard let appHomeHandler else {
            return failure(1004, "宿主尚未安装 AppHomeHandler")
        }
        guard let data = optionsJSON.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let options = value as? [String: Any] else {
            return failure(1001, "reLaunch options 必须是 JSON Object")
        }
        if let rejected = rejectOperation(
            key: "reLaunch:\(current.navigationSessionID)",
            options: navigationOptions,
            navigationController: operationNavigationController
        ) {
            return rejected
        }

        let stackBeforeHandler = rootNavigationController.viewControllers
        let firstIndex = stackBeforeHandler.firstIndex(where: {
            ($0 as? LynxContainerViewController)?.navigationSessionID ==
                current.navigationSessionID
        })
        if let firstIndex, firstIndex == 0 {
            return failure(1005, "当前 Lynx 会话前没有可返回的宿主页锚点")
        }
        let systemEntries = systemSheetEntries().filter {
            $0.navigationSessionID == current.navigationSessionID
        }
        guard firstIndex != nil || !systemEntries.isEmpty else {
            return failure(1002, "当前 Lynx 会话为空")
        }
        let rootAffectedCount = firstIndex.map { stackBeforeHandler.count - $0 } ?? 0
        let rootEntries = firstIndex.map {
            stackBeforeHandler.suffix(from: $0)
                .compactMap { $0 as? LynxContainerViewController }
        } ?? []
        let expectedAffectedCount = rootAffectedCount + systemEntries.count
        let entriesBeforeHandler = rootEntries + systemEntries
        let opened = appHomeHandler(rootNavigationController, options)
        guard opened else {
            return failure(1004, "宿主 AppHomeHandler 拒绝了主页跳转")
        }
        entriesBeforeHandler.forEach { removePendingResult(entryID: $0.navigationEntryID) }
        let stillContainsSession = rootNavigationController.viewControllers.contains(where: {
            ($0 as? LynxContainerViewController)?.navigationSessionID ==
                current.navigationSessionID
        })
        let hasSystemSheet = systemSheetNavigationController != nil
        if hasSystemSheet, stillContainsSession,
           let remainingFirstIndex = rootNavigationController.viewControllers.firstIndex(where: {
               ($0 as? LynxContainerViewController)?.navigationSessionID ==
                   current.navigationSessionID
           }) {
            guard remainingFirstIndex > 0 else {
                return failure(1005, "当前 Lynx 会话前没有可返回的宿主页锚点")
            }
            rootNavigationController.setViewControllers(
                Array(rootNavigationController.viewControllers.prefix(remainingFirstIndex)),
                animated: false
            )
            dismissSystemSheet(animated: navigationOptions.animated)
            persistNavigationSnapshot()
            return success("已返回应用主页", affectedCount: expectedAffectedCount)
        }
        if hasSystemSheet {
            dismissSystemSheet(animated: navigationOptions.animated)
        }
        if stillContainsSession {
            activateTransitionCoordinator(on: rootNavigationController)
            let closed = closeSession(
                current.navigationSessionID,
                in: rootNavigationController,
                options: ShellNavigationOptions(animated: false)
            )
            guard closed.isSuccess else { return closed }
            return success("已返回应用主页", affectedCount: expectedAffectedCount)
        }
        persistNavigationSnapshot()
        return success("已返回应用主页", affectedCount: expectedAffectedCount)
    }

    /** 兼容旧调用；使用默认导航选项原位替换栈顶 Lynx entry。 */
    @discardableResult
    func redirect(_ request: LynxPageRequest, animated: Bool = true) -> LynxNavigationResult {
        redirect(request, options: ShellNavigationOptions(animated: animated))
    }

    /**
     * 用新请求原位替换栈顶 Lynx 页面。
     *
     * entryID、sessionID、order 和返回目标保持不变，因此 A-B-C redirect(A) 得到 A-B-A。
     */
    @discardableResult
    func redirect(
        _ request: LynxPageRequest,
        options: ShellNavigationOptions
    ) -> LynxNavigationResult {
        guard let rootNavigationController = navigationController else {
            return failure(1002, "宿主导航器不可用")
        }
        let navigationController = operationNavigationController(
            root: rootNavigationController
        )
        guard let current = navigationController.topViewController as?
            LynxContainerViewController else {
            return failure(1002, "redirect 只能从 Lynx 页面发起")
        }
        if let rejected = rejectOperation(
            key: "redirect:\(current.navigationEntryID):\(request.resolvedRouteKey)",
            options: options,
            navigationController: navigationController
        ) {
            return rejected
        }
        current.replaceRequest(request)
        persistNavigationSnapshot()
        return success(
            "当前页面已重定向为 \(request.resolvedRouteKey)",
            affectedCount: 1,
            data: [
                "entryID": current.navigationEntryID,
                "routeKey": request.resolvedRouteKey,
            ]
        )
    }

    /** 返回当前 session 的 route、stack、depth、canGoBack 和宿主锚点状态。 */
    func navigationState() -> LynxNavigationResult {
        guard let rootNavigationController = navigationController else {
            return failure(1002, "宿主导航器不可用")
        }
        let navigationController = operationNavigationController(
            root: rootNavigationController
        )
        guard let current = navigationController.topViewController as?
            LynxContainerViewController else {
            return failure(1002, "当前页面不在 Lynx 导航会话中")
        }
        let controllers = logicalSessionControllers(
            sessionID: current.navigationSessionID,
            root: rootNavigationController
        )
        guard let currentIndex = controllers.lastIndex(where: { $0 === current }) else {
            return failure(1002, "当前 entry 不在 session 栈中")
        }
        let stack: [[String: Any]] = controllers.enumerated().map { index, controller in
            [
                "entryID": controller.navigationEntryID,
                "routeKey": controller.routeKey,
                "index": index,
            ]
        }
        let presentation = navigationController === systemSheetNavigationController
            ? "UISheetPresentationController"
            : "UINavigationController"
        return success(
            "导航状态读取成功",
            data: [
                "sessionID": current.navigationSessionID,
                "current": stack[currentIndex],
                "stack": stack,
                "depth": controllers.count,
                "canGoBack": currentIndex > 0,
                "hasHostAnchor": rootNavigationController.viewControllers.first !== controllers.first,
                "presentation": presentation,
            ]
        )
    }

    /** 关闭当前页并向它下面的 Lynx entry 返回 JSON Object。 */
    func closeWithResult(_ resultJSON: String) -> LynxNavigationResult {
        do {
            return back(
                delta: 1,
                options: try ShellNavigationOptions.withResultJSON(resultJSON)
            )
        } catch {
            return failure(1001, error.localizedDescription)
        }
    }

    /**
     * 一次性消费发给当前 entry 的页面结果。
     *
     * 没有结果不是错误，返回 hasResult=false；成功读取后 UserDefaults 立即删除。
     */
    func consumeNavigationResult() -> LynxNavigationResult {
        guard let rootNavigationController = navigationController,
              let current = operationNavigationController(root: rootNavigationController)
                .topViewController as? LynxContainerViewController else {
            return failure(1002, "当前页面不在 Lynx 导航会话中")
        }
        guard var value = consumeStoredResult(entryID: current.navigationEntryID) else {
            return success("当前页面没有待消费结果", data: ["hasResult": false])
        }
        value["hasResult"] = true
        return success("页面结果读取成功", data: value)
    }

    /**
     * 把当前活动 session 保存为 JSON 快照。
     *
     * 系统侧滑不经过 Native Module，容器会在 viewDidDisappear 调用本方法。
     */
    func navigationStackDidChange() {
        persistNavigationSnapshot()
    }

    /** 系统侧滑/导航栏 Back 绕过 Module 时，清理已退出 entry 的未消费结果。 */
    func entryDidClose(_ entryID: String) {
        removePendingResult(entryID: entryID)
    }

    /**
     * 在宿主根控制器建立后恢复上次活动 Lynx session。
     *
     * 只恢复 JSON 可序列化请求和 entry 元数据；无效、过期或不再满足安全策略的快照会
     * 自动删除并返回 false，由 SceneDelegate 回退到默认首页。
     */
    @discardableResult
    func restoreNavigationStackIfPossible() -> Bool {
        guard let navigationController,
              !(navigationController.topViewController is LynxContainerViewController),
              navigationController.presentedViewController == nil,
              systemSheetNavigationController == nil,
              let data = UserDefaults.standard.data(forKey: snapshotKey),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["version"] as? NSNumber)?.intValue == 1,
              let entries = root["entries"] as? [[String: Any]],
              !entries.isEmpty else {
            return false
        }

        var restored: [LynxContainerViewController] = []
        var expectedSessionID: String?
        var persistedSystemSheetEntryID: String?
        for value in entries.sorted(by: {
            (($0["order"] as? NSNumber)?.intValue ?? 0) <
                (($1["order"] as? NSNumber)?.intValue ?? 0)
        }) {
            guard let sessionID = value["sessionID"] as? String,
                  let entryID = value["entryID"] as? String,
                  let order = (value["order"] as? NSNumber)?.intValue,
                  let requestValue = value["request"] as? [String: Any],
                  let request = LynxPageRequest.fromNavigationSnapshot(requestValue) else {
                clearSavedNavigationState()
                return false
            }
            if let expectedSessionID, expectedSessionID != sessionID {
                clearSavedNavigationState()
                return false
            }
            expectedSessionID = sessionID
            let restoresAsSystemSheet = (value["systemSheetPresentation"] as? Bool) == true ||
                request.transitionSpec.routeType == .bottomSheet
            if restoresAsSystemSheet {
                guard persistedSystemSheetEntryID == nil else {
                    clearSavedNavigationState()
                    return false
                }
                persistedSystemSheetEntryID = entryID
            }
            restored.append(
                LynxContainerViewController(
                    request: request,
                    navigationSessionID: sessionID,
                    navigationEntryID: entryID,
                    navigationParentEntryID: value["parentEntryID"] as? String,
                    navigationOrder: order
                )
            )
        }
        if #available(iOS 15.0, *),
           let persistedSystemSheetEntryID,
           let sheetIndex = restored.firstIndex(where: {
               $0.navigationEntryID == persistedSystemSheetEntryID
           }) {
            let persistedSheet = restored[sheetIndex]
            let sheetRoot = LynxContainerViewController(
                request: persistedSheet.request,
                navigationSessionID: persistedSheet.navigationSessionID,
                navigationEntryID: persistedSheet.navigationEntryID,
                navigationParentEntryID: persistedSheet.navigationParentEntryID,
                navigationOrder: persistedSheet.navigationOrder,
                usesSystemSheetPresentation: true
            )
            let rootEntries = Array(restored.prefix(sheetIndex))
            let sheetEntries = [sheetRoot] + Array(restored.suffix(from: sheetIndex + 1))
            navigationController.setViewControllers(
                navigationController.viewControllers + rootEntries,
                animated: false
            )
            let sheetNavigationController = UINavigationController(
                rootViewController: sheetRoot
            )
            sheetNavigationController.setViewControllers(sheetEntries, animated: false)
            sheetNavigationController.setNavigationBarHidden(true, animated: false)
            sheetNavigationController.modalPresentationStyle = .pageSheet
            sheetNavigationController.isModalInPresentation = !(
                sheetRoot.request.transitionSpec.routeConfig.barrierDismissible ?? true
            )
            configureSystemSheet(
                sheetNavigationController,
                options: sheetRoot.request.transitionSpec.routeOptions
            )
            systemSheetController = sheetRoot
            systemSheetNavigationController = sheetNavigationController
            let presentRestoredSheet = { [weak self, weak navigationController] in
                guard let self, let navigationController,
                      self.systemSheetNavigationController === sheetNavigationController,
                      navigationController.presentedViewController == nil else {
                    return
                }
                navigationController.present(sheetNavigationController, animated: false) {
                    self.activateTransitionCoordinator(on: sheetNavigationController)
                    self.transitionCoordinator.suspendBackGestureForSystemSheet()
                    self.persistNavigationSnapshot()
                }
                sheetNavigationController.presentationController?.delegate = self
            }
            if navigationController.viewIfLoaded?.window != nil {
                presentRestoredSheet()
            } else {
                DispatchQueue.main.async(execute: presentRestoredSheet)
            }
            return true
        }
        navigationController.setViewControllers(
            navigationController.viewControllers + restored,
            animated: false
        )
        persistNavigationSnapshot()
        return true
    }

    /** 业务登出、版本切换或调试时可显式清除持久导航快照。 */
    func clearSavedNavigationState() {
        UserDefaults.standard.removeObject(forKey: snapshotKey)
    }

    /** Sheet 是当前可见容器时，Router 的“当前页”必须落在 Sheet 内部导航栈。 */
    private func operationNavigationController(
        root: UINavigationController
    ) -> UINavigationController {
        systemSheetNavigationController ?? root
    }

    /** 同一套转场协调器在根导航栈与系统 Sheet 内部导航栈之间按可见容器切换。 */
    private func activateTransitionCoordinator(on navigationController: UINavigationController) {
        transitionCoordinator.install(on: navigationController)
        if navigationController === self.navigationController {
            if let mux = navigationDelegateMux,
               navigationController.delegate !== mux {
                navigationController.delegate = mux
            }
            return
        }
        if let mux = systemSheetNavigationDelegateMux,
           navigationController.delegate === mux {
            return
        }
        let mux = ShellNavigationDelegateMux(
            transitionCoordinator: transitionCoordinator,
            downstream: navigationController.delegate
        )
        systemSheetNavigationDelegateMux = mux
        navigationController.delegate = mux
    }

    private func systemSheetEntries() -> [LynxContainerViewController] {
        systemSheetNavigationController?.viewControllers.compactMap {
            $0 as? LynxContainerViewController
        } ?? []
    }

    /** 根导航栈与系统 Sheet 导航栈共同组成一个连续的逻辑 Lynx session。 */
    private func logicalSessionControllers(
        sessionID: String,
        root: UINavigationController
    ) -> [LynxContainerViewController] {
        let rootEntries = root.viewControllers.compactMap {
            $0 as? LynxContainerViewController
        }
        return (rootEntries + systemSheetEntries())
            .filter { $0.navigationSessionID == sessionID }
            .sorted { $0.navigationOrder < $1.navigationOrder }
    }

    private func previousRootSessionController(
        before controller: LynxContainerViewController,
        root: UINavigationController
    ) -> LynxContainerViewController? {
        logicalSessionControllers(
            sessionID: controller.navigationSessionID,
            root: root
        ).last {
            $0.navigationOrder < controller.navigationOrder &&
                $0.navigationController === root
        }
    }

    @available(iOS 15.0, *)
    private func configureSystemSheet(
        _ navigationController: UINavigationController,
        options: ShellRouteOptions
    ) {
        guard let sheet = navigationController.sheetPresentationController else { return }
        let detentsVH = options.detentsVH
        if detentsVH.count == 1, let heightVH = detentsVH.first, heightVH >= 85 {
            sheet.detents = [.large()]
            sheet.selectedDetentIdentifier = .large
        } else if #available(iOS 16.0, *) {
            let identifiers = detentsVH.enumerated().map { index, heightVH in
                heightVH >= 99
                    ? UISheetPresentationController.Detent.Identifier.large
                    : UISheetPresentationController.Detent.Identifier(
                        "lynx.sheet.\(index).\(Int(heightVH.rounded()))"
                    )
            }
            sheet.detents = detentsVH.enumerated().map { index, heightVH in
                if heightVH >= 99 {
                    return .large()
                }
                return .custom(identifier: identifiers[index]) { context in
                    context.maximumDetentValue * heightVH / 100
                }
            }
            let initialIndex = min(
                max(options.initialDetentIndex, 0),
                max(identifiers.count - 1, 0)
            )
            sheet.selectedDetentIdentifier = identifiers[initialIndex]
        } else {
            // iOS 15 只有 medium/large 两个公开档位；heroSheet 在这里保留可用的
            // 两档近似，iOS 16+ 才使用完整 custom detents。
            if detentsVH.count > 1 {
                sheet.detents = [.medium(), .large()]
                sheet.selectedDetentIdentifier =
                    options.initialDetentVH >= 50 ? .large : .medium
            } else {
                sheet.detents = [.medium()]
                sheet.selectedDetentIdentifier = .medium
            }
        }
        sheet.prefersGrabberVisible = true
        sheet.preferredCornerRadius = options.round ? ShellBottomSheetMotion.sheetCornerRadius : 0
        sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        sheet.prefersEdgeAttachedInCompactHeight = true
        sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = false
        sheet.largestUndimmedDetentIdentifier = nil
    }

    private func dismissSystemSheet(animated: Bool) {
        guard let sheetNavigationController = systemSheetNavigationController else { return }
        sheetNavigationController.dismiss(animated: animated) { [weak self, weak sheetNavigationController] in
            guard let self,
                  self.systemSheetNavigationController === sheetNavigationController else {
                return
            }
            self.finishSystemSheetDismissal()
        }
    }

    /** 程序化关闭与系统下拉关闭共用幂等清理。 */
    private func finishSystemSheetDismissal() {
        guard systemSheetNavigationController != nil else { return }
        systemSheetEntries().forEach {
            removePendingResult(entryID: $0.navigationEntryID)
        }
        systemSheetController = nil
        systemSheetNavigationController = nil
        systemSheetNavigationDelegateMux = nil
        if let root = navigationController {
            activateTransitionCoordinator(on: root)
            if let current = root.topViewController as? LynxContainerViewController {
                transitionCoordinator.updateBackGesture(for: current)
            }
        }
        persistNavigationSnapshot()
    }

    /** back/popTo 跨过 Sheet 根 entry 时，根栈先落到目标，再由 UIKit 向下关闭 Sheet。 */
    private func popAcrossSystemSheet(
        source: LynxContainerViewController,
        target: LynxContainerViewController,
        closing: [LynxContainerViewController],
        requestedDelta: Int,
        actualDelta: Int,
        options: ShellNavigationOptions,
        root: UINavigationController,
        popToRouteKey: String? = nil
    ) -> LynxNavigationResult {
        guard let targetIndex = root.viewControllers.firstIndex(where: { $0 === target }) else {
            return failure(1500, "系统 Page Sheet 的根栈目标已失效")
        }
        if let result = options.result {
            storeResult(result, from: source, targetEntryID: target.navigationEntryID)
        }
        closing.forEach { removePendingResult(entryID: $0.navigationEntryID) }
        root.setViewControllers(Array(root.viewControllers.prefix(targetIndex + 1)), animated: false)
        dismissSystemSheet(animated: options.animated)
        persistNavigationSnapshot()
        var data: [String: Any] = [
            "targetEntryID": target.navigationEntryID,
            "targetRouteKey": target.routeKey,
            "presentation": "UISheetPresentationController",
        ]
        if popToRouteKey == nil {
            data["requestedDelta"] = requestedDelta
            data["actualDelta"] = actualDelta
        }
        return success(
            popToRouteKey.map { "已回退到 \($0)" } ?? "已回退 \(actualDelta) 页",
            affectedCount: closing.count,
            data: data
        )
    }

    /** clearTop/singleTask 命中 Sheet 下方 entry 时不在遮罩后偷偷 push/pop。 */
    private func clearSystemSheetToRootTarget(
        _ target: LynxContainerViewController,
        request: LynxPageRequest,
        launchMode: ShellLaunchMode,
        options: ShellNavigationOptions,
        logicalStack: [LynxContainerViewController],
        targetIndex: Int,
        root: UINavigationController
    ) -> LynxNavigationResult {
        guard let rootIndex = root.viewControllers.firstIndex(where: { $0 === target }) else {
            return failure(1500, "系统 Page Sheet 的 launchMode 目标已失效")
        }
        let removed = Array(logicalStack.suffix(from: targetIndex + 1))
        if launchMode == .singleTask {
            target.replaceRequest(request)
        }
        removed.forEach { removePendingResult(entryID: $0.navigationEntryID) }
        root.setViewControllers(Array(root.viewControllers.prefix(rootIndex + 1)), animated: false)
        dismissSystemSheet(animated: options.animated)
        persistNavigationSnapshot()
        return success(
            launchMode == .singleTask
                ? "singleTask 已复用并刷新 \(target.routeKey)"
                : "clearTop 已回到 \(target.routeKey)",
            affectedCount: removed.count + (launchMode == .singleTask ? 1 : 0),
            data: entryData(target, launchMode: launchMode).merging(
                ["presentation": "UISheetPresentationController"],
                uniquingKeysWith: { current, _ in current }
            )
        )
    }

    /** closeAll 从 Sheet 发起时，Sheet 的下落就是唯一离场动画。 */
    private func closeSessionUnderSystemSheet(
        _ sessionID: String,
        options: ShellNavigationOptions,
        root: UINavigationController
    ) -> LynxNavigationResult {
        let sheetEntries = systemSheetEntries().filter {
            $0.navigationSessionID == sessionID
        }
        let stack = root.viewControllers
        let firstRootIndex = stack.firstIndex(where: {
            ($0 as? LynxContainerViewController)?.navigationSessionID == sessionID
        })
        if let firstRootIndex {
            guard firstRootIndex > 0 else {
                return failure(1005, "当前 Lynx 会话前没有可返回的宿主页锚点")
            }
            let rootEntries = stack.suffix(from: firstRootIndex)
                .compactMap { $0 as? LynxContainerViewController }
            (rootEntries + sheetEntries).forEach {
                removePendingResult(entryID: $0.navigationEntryID)
            }
            root.setViewControllers(Array(stack.prefix(firstRootIndex)), animated: false)
            dismissSystemSheet(animated: options.animated)
            return success(
                "已关闭全部 Lynx 页面并返回进入前的宿主页",
                affectedCount: stack.count - firstRootIndex + sheetEntries.count,
                data: ["presentation": "UISheetPresentationController"]
            )
        }
        guard !sheetEntries.isEmpty else {
            return failure(1002, "当前 Lynx 会话为空")
        }
        dismissSystemSheet(animated: options.animated)
        return success(
            "已关闭全部 Lynx 页面并返回进入前的宿主页",
            affectedCount: sheetEntries.count,
            data: ["presentation": "UISheetPresentationController"]
        )
    }

    private func closeSession(
        _ sessionID: String,
        in navigationController: UINavigationController,
        options: ShellNavigationOptions
    ) -> LynxNavigationResult {
        let stack = navigationController.viewControllers
        guard let firstIndex = stack.firstIndex(where: { controller in
            (controller as? LynxContainerViewController)?.navigationSessionID == sessionID
        }) else {
            return failure(1002, "当前 Lynx 会话为空")
        }
        guard firstIndex > 0 else {
            return failure(1005, "当前 Lynx 会话前没有可返回的宿主页锚点")
        }

        let removedEntries = stack.suffix(from: firstIndex)
            .compactMap { $0 as? LynxContainerViewController }
        let remaining = Array(stack.prefix(firstIndex))
        guard let source = removedEntries.last,
              let target = remaining.last else {
            return failure(1005, "当前 Lynx 会话缺少有效的源页面或宿主页锚点")
        }
        let affectedCount = stack.count - firstIndex
        let spec = popTransitionSpec(from: source, options: options)
        let ticket = transitionCoordinator.beginPop(
            spec: spec,
            source: source,
            target: target,
            routeKey: (target as? LynxContainerViewController)?.routeKey ?? "host"
        )
        let shouldAnimate = options.animated &&
            spec.baseEffectiveStyle != .none &&
            spec.durationMilliseconds(for: .pop) > 0
        navigationController.setViewControllers(remaining, animated: shouldAnimate)
        guard navigationController.topViewController === target else {
            transitionCoordinator.failActiveTransition(reason: "native_stack_update_failed")
            return failure(1500, "closeAll 修改原生导航栈失败")
        }
        removedEntries.forEach { removePendingResult(entryID: $0.navigationEntryID) }
        if !shouldAnimate {
            transitionCoordinator.completeImmediatePop(target: target)
        }
        persistNavigationSnapshot()
        var data: [String: Any] = [:]
        appendTransition(ticket, to: &data)
        return success(
            "已关闭全部 Lynx 页面并返回进入前的宿主页",
            affectedCount: affectedCount,
            data: data
        )
    }

    /**
     * back/popTo/closeAll 默认复用“离场页当初保存的”反向转场；调用方显式传了
     * transition（包括 animated=false）时，以本次命令为准。
     */
    private func popTransitionSpec(
        from source: LynxContainerViewController,
        options: ShellNavigationOptions
    ) -> ShellTransitionSpec {
        options.transitionSpec.explicitlyRequested
            ? options.transitionSpec
            : source.request.transitionSpec
    }

    /** 把原生事务标识回传给 Native Module，便于业务只监听低频终态事件。 */
    private func appendTransition(
        _ ticket: ShellTransitionCoordinator.PushTicket,
        to data: inout [String: Any]
    ) {
        data["transactionID"] = ticket.transactionID
        data["requestedTransition"] = ticket.metadata.requestedTransition.rawValue
        data["effectiveTransition"] = ticket.metadata.effectiveTransition.rawValue
        data["status"] = ShellTransitionState.Status.accepted.rawValue
        if let reason = ticket.metadata.reason {
            data["reason"] = reason
        }
    }

    /**
     * 防止快速连点和 UIKit 转场重入。
     *
     * 返回 1006 时调用方可以在当前转场结束后重试；不会把命令悄悄放入无法回传真实
     * 错误的异步队列。
     */
    private func rejectOperation(
        key: String,
        options: ShellNavigationOptions,
        navigationController: UINavigationController
    ) -> LynxNavigationResult? {
        guard Thread.isMainThread else {
            return failure(1500, "导航操作必须在主线程执行")
        }
        if transitionCoordinator.isBusy || navigationController.transitionCoordinator != nil {
            return failure(1006, "上一笔 UIKit 转场仍在进行中")
        }
        guard options.deduplicate, options.deduplicateWindowMilliseconds > 0 else {
            return nil
        }
        let now = ProcessInfo.processInfo.systemUptime * 1_000
        guard now >= busyUntilMilliseconds else {
            return failure(
                1006,
                lastOperationKey == key ? "重复导航已抑制" : "上一笔导航事务仍在进行中"
            )
        }
        lastOperationKey = key
        let window = options.animated
            ? Double(options.deduplicateWindowMilliseconds)
            : Double(min(options.deduplicateWindowMilliseconds, 80))
        busyUntilMilliseconds = now + window
        return nil
    }

    /** 只保存当前栈顶所属的 Lynx session；未知原生控制器不会被序列化。 */
    private func persistNavigationSnapshot() {
        guard let rootNavigationController = navigationController else {
            clearSavedNavigationState()
            return
        }
        let activeNavigationController = operationNavigationController(
            root: rootNavigationController
        )
        guard let current = activeNavigationController.topViewController as?
            LynxContainerViewController else {
            clearSavedNavigationState()
            return
        }
        let entries = logicalSessionControllers(
            sessionID: current.navigationSessionID,
            root: rootNavigationController
        ).map(\.navigationSnapshot)
        let snapshot: [String: Any] = [
            "version": 1,
            "entries": entries,
            "updatedAt": Date().timeIntervalSince1970,
        ]
        guard JSONSerialization.isValidJSONObject(snapshot),
              let data = try? JSONSerialization.data(withJSONObject: snapshot) else {
            clearSavedNavigationState()
            return
        }
        UserDefaults.standard.set(data, forKey: snapshotKey)
    }

    /** 返回结果按目标 entryID 持久化，避免依赖会随页面销毁失效的 JS callback 闭包。 */
    private func storeResult(
        _ result: [String: Any],
        from source: LynxContainerViewController,
        targetEntryID: String
    ) {
        let envelope: [String: Any] = [
            "result": result,
            "sourceEntryID": source.navigationEntryID,
            "sourceRouteKey": source.routeKey,
            "createdAt": Date().timeIntervalSince1970,
        ]
        guard JSONSerialization.isValidJSONObject(envelope),
              let data = try? JSONSerialization.data(withJSONObject: envelope) else {
            return
        }
        UserDefaults.standard.set(data, forKey: resultKeyPrefix + targetEntryID)
    }

    /** remove-before-return，保证同一页面结果最多消费一次。 */
    private func consumeStoredResult(entryID: String) -> [String: Any]? {
        let key = resultKeyPrefix + entryID
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: key) else { return nil }
        defaults.removeObject(forKey: key)
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func removePendingResult(entryID: String) {
        UserDefaults.standard.removeObject(forKey: resultKeyPrefix + entryID)
    }

    private func entryData(
        _ controller: LynxContainerViewController,
        launchMode: ShellLaunchMode
    ) -> [String: Any] {
        [
            "entryID": controller.navigationEntryID,
            "routeKey": controller.routeKey,
            "launchMode": launchMode.rawValue,
        ]
    }

    private func success(
        _ message: String,
        affectedCount: Int = 0,
        data: [String: Any] = [:]
    ) -> LynxNavigationResult {
        LynxNavigationResult(
            code: 0,
            message: message,
            affectedCount: affectedCount,
            data: data
        )
    }

    private func failure(_ code: Int, _ message: String) -> LynxNavigationResult {
        LynxNavigationResult(code: code, message: message, affectedCount: 0, data: [:])
    }
}
