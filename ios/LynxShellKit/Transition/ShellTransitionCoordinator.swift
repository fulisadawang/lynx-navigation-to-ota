import Lynx
import UIKit

/**
 * 原生转场事务、UINavigationController delegate 与 edge/full-screen pop 的唯一所有者。
 *
 * NativeModules 只声明一次路由意图；动画进度完全由 UIKit/手势在主线程推进。
 */
final class ShellTransitionCoordinator: NSObject, UIGestureRecognizerDelegate {
    struct PushTicket {
        let transactionID: String
        let metadata: ShellNativeTransitionMetadata
    }

    private final class Transaction {
        let id: String
        let requested: ShellTransitionStyle
        var effective: ShellTransitionStyle
        let direction: ShellTransitionDirection
        let spec: ShellTransitionSpec
        let routeKey: String
        /** clearTop/singleTask 即使没有显式 style，也必须由壳拥有 animator。 */
        let forceCustomAnimator: Bool
        weak var source: UIViewController?
        weak var target: UIViewController?
        /** 预建目标尚未进 UINavigationController 栈时必须由事务临时强持有。 */
        var retainedTarget: UIViewController?
        /** 无动画 setViewControllers 会立即释放源 VC，事务需保留到终态事件发送。 */
        var retainedSource: UIViewController?
        var reason: String?
        var interaction: UIPercentDrivenInteractiveTransition?
        var animator: ShellNavigationAnimator?
        /** 交互返回时仅让显式允许 transitionOnGesture 的共享元素跟手。 */
        var interactiveSharedElementKeys: Set<String>?
        var completion: (() -> Void)?
        var businessReady = false
        var routeDoneSent = false

        init(
            id: String = UUID().uuidString,
            requested: ShellTransitionStyle,
            effective: ShellTransitionStyle,
            direction: ShellTransitionDirection,
            spec: ShellTransitionSpec,
            routeKey: String,
            reason: String?,
            forceCustomAnimator: Bool = false
        ) {
            self.id = id
            self.requested = requested
            self.effective = effective
            self.direction = direction
            self.spec = spec
            self.routeKey = routeKey
            self.reason = reason
            self.forceCustomAnimator = forceCustomAnimator
        }
    }

    private weak var navigationController: UINavigationController?
    private let edgePan = UIScreenEdgePanGestureRecognizer()
    private let fullPan = UIPanGestureRecognizer()
    private enum GestureAxis {
        case horizontal
        case vertical
    }
    private var activeGestureAxis: GestureAxis = .horizontal
    /** 进入首个 Lynx VC 前记录宿主系统侧滑开关，退出 Lynx 页面后原样恢复。 */
    private var hostInteractivePopGestureEnabled: Bool?
    /** 进入 Lynx 栈前记录宿主的系统侧滑 delegate，离开时恢复，避免污染宿主页面。 */
    private weak var hostInteractivePopGestureDelegate: UIGestureRecognizerDelegate?
    private var active: Transaction?
    private(set) var state: ShellTransitionState = .idle

    var isBusy: Bool {
        guard let active else { return false }
        return [
            ShellTransitionState.Status.accepted,
            .waitingTarget,
            .running,
            .settling,
        ].contains(state.status) && !active.id.isEmpty
    }

    func install(on navigationController: UINavigationController) {
        if self.navigationController === navigationController { return }
        if let old = self.navigationController {
            old.view.removeGestureRecognizer(edgePan)
            old.view.removeGestureRecognizer(fullPan)
        }
        self.navigationController = navigationController
        edgePan.edges = .left
        edgePan.delegate = self
        edgePan.addTarget(self, action: #selector(handleEdgePan(_:)))
        edgePan.isEnabled = false
        fullPan.delegate = self
        fullPan.maximumNumberOfTouches = 1
        fullPan.addTarget(self, action: #selector(handleFullPan(_:)))
        fullPan.isEnabled = false
        navigationController.view.addGestureRecognizer(edgePan)
        navigationController.view.addGestureRecognizer(fullPan)
    }

    /** 在创建目标 VC 之前冻结 transactionID，供 globalProps 首屏读取。 */
    func beginPush(
        spec: ShellTransitionSpec,
        routeKey: String,
        additionalReason: String? = nil
    ) -> PushTicket {
        dispatchPrecondition(condition: .onQueue(.main))
        var effective = spec.baseEffectiveStyle
        var reason = additionalReason ?? spec.initialReason
        if spec.durationMilliseconds(for: .push) == 0 {
            effective = .none
        } else if spec.explicitlyRequested, effective == .default {
            // 显式 style=default 仍由壳接管，以稳定 slide 代替 UIKit 私有默认 animator。
            effective = .slide
        }
        if UIAccessibility.isReduceMotionEnabled,
           ![ShellTransitionStyle.default, .none, .fade].contains(effective) {
            effective = spec.fallbackStyle == .none ? .none : .fade
            reason = "reduce_motion"
        }
        let transaction = Transaction(
            requested: spec.requestedStyle,
            effective: effective,
            direction: .push,
            spec: spec,
            routeKey: routeKey,
            reason: reason
        )
        active = transaction
        updateState(for: transaction, status: .accepted, progress: 0)
        return PushTicket(
            transactionID: transaction.id,
            metadata: metadata(for: transaction)
        )
    }

    /**
     * clearTop/singleTask/back/popTo/closeAll 共用的显式 pop 事务入口。
     *
     * 调用方必须在真正修改 UINavigationController 栈之前调用；即使 animated=false，
     * 事务也会保留到 completeImmediatePop，确保 none 路径仍发送终态事件。
     */
    @discardableResult
    func beginPop(
        spec: ShellTransitionSpec,
        source: UIViewController,
        target: UIViewController,
        routeKey: String,
        forceCustomAnimator: Bool = false
    ) -> PushTicket {
        dispatchPrecondition(condition: .onQueue(.main))
        let transaction = makePopTransaction(
            spec: spec,
            from: source,
            to: target,
            routeKey: routeKey,
            forceCustomAnimator: forceCustomAnimator
        )
        transaction.retainedSource = source
        active = transaction
        updateState(for: transaction, status: .accepted, progress: 0)
        return PushTicket(
            transactionID: transaction.id,
            metadata: metadata(for: transaction)
        )
    }

    /** 无动画栈修改通常不回调 didShow；下一主线程 tick 主动幂等收口。 */
    func completeImmediatePop(target: UIViewController) {
        dispatchPrecondition(condition: .onQueue(.main))
        DispatchQueue.main.async { [weak self, weak target] in
            guard let self, let target,
                  let transaction = self.active,
                  transaction.direction == .pop,
                  transaction.target === target else {
                return
            }
            self.didShow(target, animated: false)
        }
    }

    /** 已接受但未能修改原生栈时发送 failed settled，并释放事务。 */
    func failActiveTransition(reason: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let transaction = active else { return }
        transaction.reason = reason
        updateState(for: transaction, status: .failed, progress: state.progress)
        emitRouteDone(for: transaction)
        transaction.completion = nil
        transaction.interaction = nil
        transaction.animator = nil
        transaction.retainedSource = nil
        transaction.retainedTarget = nil
        active = nil
    }

    /** 自定义转场期间导航栏显隐也禁止使用 UIKit 自带动画。 */
    func allowsSystemChromeAnimation(for controller: LynxContainerViewController) -> Bool {
        if let transaction = active {
            return transaction.effective == .default &&
                !transaction.spec.explicitlyRequested
        }
        return !controller.request.transitionSpec.explicitlyRequested
    }

    /**
     * 有界等待目标首屏后才真正 push；等待/selector 失败只降级动画，不失败导航。
     */
    func commitPush(
        target: LynxContainerViewController,
        sourceLynxView: LynxView?,
        navigationController: UINavigationController,
        completion: @escaping () -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let transaction = active, transaction.direction == .push else { return }
        transaction.target = target
        transaction.retainedTarget = target
        transaction.source = sourceController(
            for: sourceLynxView,
            in: navigationController
        ) ?? navigationController.topViewController
        transaction.completion = completion

        let sourceAllowsTransition = (
            transaction.source as? LynxContainerViewController
        )?.request.transitionSpec.routeConfig.canTransitionTo ?? true
        if !sourceAllowsTransition || !transaction.spec.routeConfig.canTransitionFrom {
            degrade(
                transaction,
                reason: "route_transition_blocked",
                target: target
            )
            push(transaction, target: target, in: navigationController)
            return
        }

        guard transaction.spec.needsTargetReadiness,
              transaction.effective == transaction.spec.baseEffectiveStyle else {
            push(transaction, target: target, in: navigationController)
            return
        }

        if let source = transaction.source as? LynxContainerViewController,
           source.request.fullscreen != target.request.fullscreen ||
            source.request.showNavigationBar != target.request.showNavigationBar ||
            source.request.hideStatusBar != target.request.hideStatusBar {
            degrade(transaction, reason: "window_geometry_changed", target: target)
            push(transaction, target: target, in: navigationController)
            return
        }

        if let failure = sourceValidationFailure(for: transaction) {
            degrade(transaction, reason: failure, target: target)
            push(transaction, target: target, in: navigationController)
            return
        }

        updateState(for: transaction, status: .waitingTarget, progress: 0)
        target.waitUntilFirstScreen(
            timeoutMilliseconds: transaction.spec.readyTimeoutMilliseconds
        ) { [weak self, weak target, weak navigationController] ready, reason in
            guard let self, let target, let navigationController,
                  self.active === transaction else {
                return
            }
            if !ready {
                self.degrade(transaction, reason: reason ?? "target_not_ready", target: target)
            } else if transaction.effective == .sharedElement,
                      transaction.spec.sharedElements.contains(where: {
                          target.resolveElement(idSelector: $0.targetSelector) == nil
                      }) {
                self.degrade(transaction, reason: "target_selector_missing", target: target)
            }
            self.push(transaction, target: target, in: navigationController)
        }
    }

    /** JS 的可选 ready 信号只确认业务内容稳定，不接受坐标或逐帧 progress。 */
    func markReady(transactionID: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let active, active.id == transactionID else { return false }
        active.businessReady = true
        return true
    }

    func currentState() -> ShellTransitionState {
        dispatchPrecondition(condition: .onQueue(.main))
        return state
    }

    /** Scene 进入后台时取消未提交/交互事务，绝不恢复旧动画进度。 */
    func cancelForBackground() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let transaction = active else { return }
        transaction.reason = "app_backgrounded"
        if let interaction = transaction.interaction {
            updateState(for: transaction, status: .settling, progress: state.progress)
            transaction.animator?.settleInteractive(completed: false)
            interaction.cancel()
        } else if state.status == .waitingTarget || state.status == .accepted {
            updateState(for: transaction, status: .cancelled, progress: state.progress)
            emitRouteDone(for: transaction)
            transaction.retainedTarget = nil
            active = nil
        }
    }

    /** 容器显示时在系统 edge 与壳自定义 edge 之间只启用一个。 */
    func updateBackGesture(for controller: LynxContainerViewController) {
        guard let navigationController else { return }
        // 目标 VC 的 viewWillAppear 会在交互转场尚未结束时触发。此时必须继续由源
        // 手势驱动；完成/取消后 didShow 会用最终可见 VC 再调用本方法。
        guard !isBusy, navigationController.transitionCoordinator == nil else { return }
        applyBackGesture(for: controller, in: navigationController)
    }

    private func applyBackGesture(
        for controller: LynxContainerViewController,
        in navigationController: UINavigationController
    ) {
        if hostInteractivePopGestureEnabled == nil {
            hostInteractivePopGestureEnabled =
                navigationController.interactivePopGestureRecognizer?.isEnabled
        }
        // UINavigationController 被壳接管 delegate 后，UIKit 默认的 interactive-pop
        // delegate 在部分系统版本不会再允许启动。Lynx 页面可见期间由壳做同等边界判断，
        // 离开 Lynx 栈时在 releaseBackGestureOwnership() 中恢复宿主 delegate。
        if let systemPop = navigationController.interactivePopGestureRecognizer,
           systemPop.delegate !== self {
            hostInteractivePopGestureDelegate = systemPop.delegate
            systemPop.delegate = self
        }
        let canGoBack = controller.request.backGestureEnabled &&
            navigationController.viewControllers.count > 1
        let gestureAllowed = canGoBack &&
            controller.request.transitionSpec.popGesture.enabled
        let spec = controller.request.transitionSpec
        let style = spec.baseEffectiveStyle
        let usesCustom = gestureAllowed && spec.usesCustomAnimator && style != .none
        let usesFullPan = usesCustom && (
            spec.popGesture.fullScreen ||
                spec.popGesture.direction != .horizontal
        )
        edgePan.isEnabled = usesCustom && !usesFullPan
        fullPan.isEnabled = usesFullPan
        navigationController.interactivePopGestureRecognizer?.isEnabled =
            gestureAllowed && !usesCustom && style != .none
    }

    /**
     * 栈顶离开 Lynx 容器时释放壳手势所有权。
     *
     * 这里同时恢复进入 Lynx 前的开关和 delegate，downstream 仍会在 didShow 回调中
     * 最后决定宿主页面自己的导航策略。
     */
    private func releaseBackGestureOwnership() {
        edgePan.isEnabled = false
        fullPan.isEnabled = false
        if let systemPop = navigationController?.interactivePopGestureRecognizer {
            if let enabled = hostInteractivePopGestureEnabled {
                systemPop.isEnabled = enabled
            }
            if systemPop.delegate === self {
                systemPop.delegate = hostInteractivePopGestureDelegate
            }
        }
        hostInteractivePopGestureEnabled = nil
        hostInteractivePopGestureDelegate = nil
    }

    func animationController(
        operation: UINavigationController.Operation,
        from fromController: UIViewController,
        to toController: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        dispatchPrecondition(condition: .onQueue(.main))
        let transaction: Transaction
        if let current = active,
           current.source === fromController || current.target === toController ||
            current.target === fromController {
            transaction = current
        } else if operation == .pop,
                  let source = fromController as? LynxContainerViewController {
            transaction = makeProgrammaticPop(
                from: source,
                to: toController
            )
            active = transaction
            updateState(for: transaction, status: .accepted, progress: 0)
        } else {
            return nil
        }

        transaction.source = fromController
        transaction.target = toController
        // routeType 已经带降级原因、但 effective 尚未被前置校验改写时，也必须
        // 真正切换到 fallback renderer；仅跳过 preset 会错误地继续跑 diagnosticStyle。
        if transaction.reason != nil,
           transaction.spec.routeType != nil,
           transaction.effective == transaction.spec.baseEffectiveStyle {
            transaction.effective = transaction.spec.fallbackStyle
            if let target = transaction.target as? LynxContainerViewController {
                target.updateNativeTransition(metadata(for: transaction))
            }
            updateState(
                for: transaction,
                status: .accepted,
                progress: state.progress
            )
        }
        if transaction.effective == .default &&
            !transaction.spec.explicitlyRequested &&
            !transaction.forceCustomAnimator {
            return nil
        }
        let animator = ShellNavigationAnimator(
            operation: operation,
            requestedStyle: transaction.requested,
            effectiveStyle: transaction.effective,
            spec: transaction.spec,
            interactiveSharedElementKeys: transaction.interactiveSharedElementKeys,
            initiallyDegraded: transaction.reason != nil,
            onFallback: { [weak self, weak transaction] fallback, reason in
                guard let self, let transaction, self.active === transaction else { return }
                transaction.effective = fallback
                transaction.reason = reason
                if let target = transaction.target as? LynxContainerViewController {
                    target.updateNativeTransition(self.metadata(for: transaction))
                }
                self.updateState(for: transaction, status: .running, progress: self.state.progress)
            }
        )
        transaction.animator = animator
        return animator
    }

    func interactionController(
        for animator: UIViewControllerAnimatedTransitioning
    ) -> UIViewControllerInteractiveTransitioning? {
        guard let transaction = active,
              transaction.animator === animator else {
            return nil
        }
        return transaction.interaction
    }

    func willShow(_ controller: UIViewController, animated: Bool) {
        guard let transaction = active else { return }
        if controller === transaction.target {
            updateState(for: transaction, status: .running, progress: state.progress)
        }
        // downstream 的 willShow 可能调整系统 recognizer；交互期最后重新声明源页面
        // 的所有权，防止两个返回手势同时处于 enabled。
        if let navigationController,
           let source = transaction.source as? LynxContainerViewController {
            applyBackGesture(for: source, in: navigationController)
        }
    }

    func didShow(_ controller: UIViewController, animated: Bool) {
        guard let transaction = active else { return }
        let completed = controller === transaction.target
        let cancelled = controller === transaction.source
        guard completed || cancelled else { return }

        if completed {
            updateState(
                for: transaction,
                status: transaction.reason == nil ? .completed : .degraded,
                progress: 1
            )
            transaction.completion?()
        } else {
            updateState(for: transaction, status: .cancelled, progress: 0)
        }
        emitRouteDone(for: transaction)
        transaction.completion = nil
        transaction.interaction = nil
        transaction.animator = nil
        transaction.retainedSource = nil
        transaction.retainedTarget = nil
        active = nil
        if let shown = controller as? LynxContainerViewController {
            updateBackGesture(for: shown)
        } else {
            releaseBackGestureOwnership()
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard !isBusy,
              let navigationController,
              navigationController.transitionCoordinator == nil,
              navigationController.viewControllers.count > 1,
              let current = navigationController.topViewController as? LynxContainerViewController,
              current.request.backGestureEnabled,
              current.request.transitionSpec.popGesture.enabled else {
            return false
        }

        // 标准 iOS 横向侧滑走系统 interactive-pop；自定义转场仍由 edgePan/fullPan
        // 处理，避免同一个手势被两个 percent-driven 事务同时消费。
        if gestureRecognizer === navigationController.interactivePopGestureRecognizer {
            let spec = current.request.transitionSpec
            return spec.baseEffectiveStyle != .none &&
                !spec.usesCustomAnimator &&
                spec.popGesture.direction == .horizontal &&
                !spec.popGesture.fullScreen
        }

        guard gestureRecognizer === edgePan || gestureRecognizer === fullPan else {
            return false
        }
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let popGesture = current.request.transitionSpec.popGesture
        let velocity = pan.velocity(in: navigationController.view)
        let location = pan.location(in: navigationController.view)
        if gestureRecognizer === edgePan {
            guard popGesture.direction == .horizontal,
                  location.x <= popGesture.edgeWidth else {
                return false
            }
            activeGestureAxis = .horizontal
            return velocity.x >= max(abs(velocity.y), 80)
        }

        let axis: GestureAxis
        let primaryVelocity: CGFloat
        let crossVelocity: CGFloat
        switch popGesture.direction {
        case .horizontal:
            axis = .horizontal
            primaryVelocity = velocity.x
            crossVelocity = velocity.y
        case .vertical:
            axis = .vertical
            primaryVelocity = velocity.y
            crossVelocity = velocity.x
        case .multi:
            if abs(velocity.x) >= abs(velocity.y) {
                axis = .horizontal
                primaryVelocity = velocity.x
                crossVelocity = velocity.y
            } else {
                axis = .vertical
                primaryVelocity = velocity.y
                crossVelocity = velocity.x
            }
        }
        // 全屏/纵向返回必须先形成明确的“向后”意图；轻微抖动不能抢走
        // Lynx scroll-view 的点击或滚动手势。
        guard primaryVelocity >= max(abs(crossVelocity), 80),
              scrollViewsAllowPop(
                  at: location,
                  in: navigationController.view,
                  axis: axis
              ) else {
            return false
        }
        activeGestureAxis = axis
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // 系统 interactivePop 与壳 edge pop 必须由且只由其中一个驱动。
        false
    }

    /**
     * 只有触点路径上的 scroll-view 已在返回方向边界，才允许全屏/纵向 pop。
     *
     * 同时检查全部祖先而非只看最近一层：嵌套横向列表位于左边界、但外层仍可向左
     * 滚动时，仍应把手势留给外层。非目标轴可滚动不会阻塞返回。
     */
    private func scrollViewsAllowPop(
        at location: CGPoint,
        in rootView: UIView,
        axis: GestureAxis
    ) -> Bool {
        var candidate = rootView.hitTest(location, with: nil)
        while let view = candidate {
            if let scrollView = view as? UIScrollView,
               scrollView.isScrollEnabled {
                let inset = scrollView.adjustedContentInset
                switch axis {
                case .horizontal:
                    let scrollableWidth = scrollView.contentSize.width +
                        inset.left + inset.right
                    if scrollableWidth > scrollView.bounds.width + 1,
                       scrollView.contentOffset.x > -inset.left + 1 {
                        return false
                    }
                case .vertical:
                    let scrollableHeight = scrollView.contentSize.height +
                        inset.top + inset.bottom
                    if scrollableHeight > scrollView.bounds.height + 1,
                       scrollView.contentOffset.y > -inset.top + 1 {
                        return false
                    }
                }
            }
            candidate = view.superview
        }
        return true
    }

    @objc private func handleEdgePan(_ gesture: UIScreenEdgePanGestureRecognizer) {
        activeGestureAxis = .horizontal
        handlePan(gesture)
    }

    @objc private func handleFullPan(_ gesture: UIPanGestureRecognizer) {
        handlePan(gesture)
    }

    /** horizontal/vertical/multi 最终都归一到同一个 percent-driven 事务。 */
    private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let navigationController else { return }
        let bounds = navigationController.view.bounds
        let translation = gesture.translation(in: navigationController.view)
        let distance: CGFloat
        let dimension: CGFloat
        switch activeGestureAxis {
        case .horizontal:
            distance = translation.x
            dimension = max(bounds.width, 1)
        case .vertical:
            distance = translation.y
            dimension = max(bounds.height, 1)
        }
        let progress = min(max(distance / dimension, 0), 1)

        switch gesture.state {
        case .began:
            guard let source = navigationController.topViewController as? LynxContainerViewController,
                  navigationController.viewControllers.count > 1 else {
                return
            }
            let target = navigationController.viewControllers[
                navigationController.viewControllers.count - 2
            ]
            let transaction = makeProgrammaticPop(from: source, to: target)
            if transaction.effective == .sharedElement {
                let eligibleKeys = Set(
                    transaction.spec.sharedElements
                        .filter(\.transitionOnGesture)
                        .map(\.key)
                )
                if eligibleKeys.isEmpty {
                    transaction.effective = transaction.spec.fallbackStyle
                    transaction.reason = "gesture_shared_element_unavailable"
                } else if eligibleKeys.count < transaction.spec.sharedElements.count {
                    transaction.interactiveSharedElementKeys = eligibleKeys
                }
            }
            transaction.interaction = UIPercentDrivenInteractiveTransition()
            transaction.interaction?.completionCurve = .easeOut
            active = transaction
            updateState(for: transaction, status: .accepted, progress: 0)
            navigationController.popViewController(animated: true)

        case .changed:
            guard let transaction = active, let interaction = transaction.interaction else { return }
            interaction.update(progress)
            transaction.animator?.updateInteractiveProgress(progress)
            updateState(for: transaction, status: .running, progress: progress)

        case .ended:
            guard let transaction = active, let interaction = transaction.interaction else { return }
            let rawVelocity = gesture.velocity(in: navigationController.view)
            let velocity = max(
                activeGestureAxis == .horizontal ? rawVelocity.x : rawVelocity.y,
                0
            )
            let shouldFinish = progress >= 0.42 || (progress >= 0.12 && velocity >= 700)
            updateState(for: transaction, status: .settling, progress: progress)
            transaction.animator?.settleInteractive(completed: shouldFinish)
            if shouldFinish {
                interaction.finish()
            } else {
                interaction.cancel()
            }

        case .cancelled, .failed:
            guard let transaction = active, let interaction = transaction.interaction else { return }
            updateState(for: transaction, status: .settling, progress: progress)
            transaction.animator?.settleInteractive(completed: false)
            interaction.cancel()

        default:
            break
        }
    }

    private func push(
        _ transaction: Transaction,
        target: LynxContainerViewController,
        in navigationController: UINavigationController
    ) {
        guard active === transaction else { return }
        let animated = transaction.effective != .none
        navigationController.pushViewController(target, animated: animated)
        // pushViewController 返回后 UINavigationController 已强持有目标。
        transaction.retainedTarget = nil
        if !animated {
            // 无动画路径在部分系统版本不会稳定触发 didShow，主动收口且幂等。
            DispatchQueue.main.async { [weak self, weak target] in
                guard let self, let target, self.active === transaction else { return }
                self.didShow(target, animated: false)
            }
        }
    }

    private func sourceValidationFailure(for transaction: Transaction) -> String? {
        guard let source = transaction.source as? LynxContainerViewController else {
            return "source_selector_missing"
        }
        switch transaction.effective {
        case .sharedElement:
            guard !transaction.spec.sharedElements.isEmpty,
                  !transaction.spec.sharedElements.contains(where: {
                      source.resolveElement(idSelector: $0.sourceSelector) == nil
                  }) else {
                return "source_selector_missing"
            }
        case .openContainer:
            guard let selector = transaction.spec.openContainer?.sourceSelector,
                  source.resolveElement(idSelector: selector) != nil else {
                return "source_selector_missing"
            }
        default:
            break
        }
        return nil
    }

    private func degrade(
        _ transaction: Transaction,
        reason: String,
        target: LynxContainerViewController
    ) {
        transaction.effective = transaction.spec.fallbackStyle
        transaction.reason = reason
        target.updateNativeTransition(metadata(for: transaction))
        updateState(for: transaction, status: .accepted, progress: 0)
    }

    private func makeProgrammaticPop(
        from source: LynxContainerViewController,
        to target: UIViewController
    ) -> Transaction {
        makePopTransaction(
            spec: source.request.transitionSpec,
            from: source,
            to: target,
            routeKey: (target as? LynxContainerViewController)?.routeKey ?? "host"
        )
    }

    private func makePopTransaction(
        spec: ShellTransitionSpec,
        from source: UIViewController,
        to target: UIViewController,
        routeKey: String,
        forceCustomAnimator: Bool = false
    ) -> Transaction {
        var effective = spec.baseEffectiveStyle
        var reason = spec.initialReason
        if spec.durationMilliseconds(for: .pop) == 0 {
            effective = .none
        } else if (spec.explicitlyRequested || forceCustomAnimator),
                  effective == .default {
            effective = .slide
        }
        if UIAccessibility.isReduceMotionEnabled,
           ![ShellTransitionStyle.default, .none, .fade].contains(effective) {
            effective = spec.fallbackStyle == .none ? .none : .fade
            reason = "reduce_motion"
        }
        // pop 是 push 的反向：目标旧页 canTransitionTo(源新页)，
        // 源新页 canTransitionFrom(目标旧页)，不能按视觉方向对调。
        let targetAllowsTransitionTo = (
            target as? LynxContainerViewController
        )?.request.transitionSpec.routeConfig.canTransitionTo ?? true
        if !spec.routeConfig.canTransitionFrom || !targetAllowsTransitionTo {
            effective = spec.fallbackStyle
            reason = "route_transition_blocked"
        }
        let transaction = Transaction(
            requested: spec.requestedStyle,
            effective: effective,
            direction: .pop,
            spec: spec,
            routeKey: routeKey,
            reason: reason,
            forceCustomAnimator: forceCustomAnimator
        )
        transaction.source = source
        transaction.target = target
        return transaction
    }

    private func sourceController(
        for lynxView: LynxView?,
        in navigationController: UINavigationController
    ) -> LynxContainerViewController? {
        navigationController.viewControllers.reversed()
            .compactMap { $0 as? LynxContainerViewController }
            .first(where: { $0.owns(lynxView) })
    }

    private func metadata(for transaction: Transaction) -> ShellNativeTransitionMetadata {
        ShellNativeTransitionMetadata(
            transactionID: transaction.id,
            requestedTransition: transaction.requested,
            effectiveTransition: transaction.effective,
            direction: transaction.direction,
            reason: transaction.reason
        )
    }

    private func updateState(
        for transaction: Transaction,
        status: ShellTransitionState.Status,
        progress: CGFloat
    ) {
        state = ShellTransitionState(
            transactionID: transaction.id,
            status: status,
            requestedTransition: transaction.requested,
            effectiveTransition: transaction.effective,
            direction: transaction.direction,
            progress: min(max(progress, 0), 1),
            reason: transaction.reason,
            routeKey: transaction.routeKey,
            updatedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
        )
    }

    /**
     * 仅在一次事务真正 settle 后发送，避免 JS 参与逐帧动画。
     *
     * source/target 都可能需要恢复临时 hero 状态，因此向仍存活的两个 LynxView 各发
     * onTransitionSettled；只有导航已提交的 completed/degraded 才另发 onRouteDone。
     */
    private func emitRouteDone(for transaction: Transaction) {
        guard !transaction.routeDoneSent,
              [.completed, .cancelled, .degraded, .failed].contains(state.status) else {
            return
        }
        transaction.routeDoneSent = true
        var payload = state.dictionary
        payload["completed"] = state.status == .completed || state.status == .degraded
        payload["cancelled"] = state.status == .cancelled
        payload["degraded"] = state.status == .degraded
        payload["failed"] = state.status == .failed

        var emitted = Set<ObjectIdentifier>()
        [transaction.source, transaction.target]
            .compactMap { $0 as? LynxContainerViewController }
            .forEach { controller in
                let identifier = ObjectIdentifier(controller)
                guard emitted.insert(identifier).inserted else { return }
                controller.sendTransitionSettled(payload)
                if state.status == .completed || state.status == .degraded {
                    controller.sendRouteDone(payload)
                }
            }
    }
}

/**
 * 组合壳转场能力与宿主已有 UINavigationControllerDelegate。
 *
 * UINavigationController 对 delegate 是 weak，ShellNavigator 会强持有本 mux；未被壳
 * 接管的原生页面/默认动画继续显式转发给 downstream。
 */
final class ShellNavigationDelegateMux: NSObject, UINavigationControllerDelegate {
    let transitionCoordinator: ShellTransitionCoordinator
    weak var downstream: UINavigationControllerDelegate?

    init(
        transitionCoordinator: ShellTransitionCoordinator,
        downstream: UINavigationControllerDelegate?
    ) {
        self.transitionCoordinator = transitionCoordinator
        self.downstream = downstream
        super.init()
    }

    func navigationController(
        _ navigationController: UINavigationController,
        animationControllerFor operation: UINavigationController.Operation,
        from fromVC: UIViewController,
        to toVC: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        transitionCoordinator.animationController(operation: operation, from: fromVC, to: toVC)
            ?? downstream?.navigationController?(
                navigationController,
                animationControllerFor: operation,
                from: fromVC,
                to: toVC
            )
    }

    func navigationController(
        _ navigationController: UINavigationController,
        interactionControllerFor animationController: UIViewControllerAnimatedTransitioning
    ) -> UIViewControllerInteractiveTransitioning? {
        if animationController is ShellNavigationAnimator {
            // 壳 animator 只能由壳创建的 UIPercentDrivenInteractiveTransition 驱动。
            return transitionCoordinator.interactionController(for: animationController)
        }
        return downstream?.navigationController?(
                navigationController,
                interactionControllerFor: animationController
            )
    }

    func navigationController(
        _ navigationController: UINavigationController,
        willShow viewController: UIViewController,
        animated: Bool
    ) {
        downstream?.navigationController?(
            navigationController,
            willShow: viewController,
            animated: animated
        )
        // 壳最后重申进行中事务的手势所有权。
        transitionCoordinator.willShow(viewController, animated: animated)
    }

    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        if viewController is LynxContainerViewController {
            downstream?.navigationController?(
                navigationController,
                didShow: viewController,
                animated: animated
            )
            // Lynx 页面可见时壳最后落手势开关。
            transitionCoordinator.didShow(viewController, animated: animated)
        } else {
            // 回到原生页面时壳先释放，再让宿主 delegate 最后决定自己的策略。
            transitionCoordinator.didShow(viewController, animated: animated)
            downstream?.navigationController?(
                navigationController,
                didShow: viewController,
                animated: animated
            )
        }
    }

    func navigationControllerSupportedInterfaceOrientations(
        _ navigationController: UINavigationController
    ) -> UIInterfaceOrientationMask {
        downstream?.navigationControllerSupportedInterfaceOrientations?(navigationController)
            ?? navigationController.topViewController?.supportedInterfaceOrientations
            ?? .allButUpsideDown
    }

    func navigationControllerPreferredInterfaceOrientationForPresentation(
        _ navigationController: UINavigationController
    ) -> UIInterfaceOrientation {
        downstream?.navigationControllerPreferredInterfaceOrientationForPresentation?(
            navigationController
        ) ?? navigationController.topViewController?.preferredInterfaceOrientationForPresentation
            ?? .portrait
    }
}
