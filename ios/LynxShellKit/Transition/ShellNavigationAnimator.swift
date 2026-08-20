import UIKit

/**
 * 一次 UINavigationController push/pop 的可中断动画器。
 *
 * 只要页面显式声明 transition/routeType，本动画器就持有完整生命周期；即使共享元素、
 * Open Container 的 selector 或 snapshot 失败，也只会切到壳 fallback，不会把动画
 * 交还 UIKit。所有插值都在主线程执行，不逐帧调用 NativeModules/JS。
 */
final class ShellNavigationAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let operation: UINavigationController.Operation
    private let requestedStyle: ShellTransitionStyle
    private var effectiveStyle: ShellTransitionStyle
    private let spec: ShellTransitionSpec
    private let interactiveSharedElementKeys: Set<String>?
    private var didFallback: Bool
    private let onFallback: (ShellTransitionStyle, String) -> Void
    private var propertyAnimator: UIViewPropertyAnimator?
    private weak var activeContext: UIViewControllerContextTransitioning?
    private var cleanup: (() -> Void)?
    private var completionFinalizer: ((Bool) -> Void)?
    private var interactiveTransition = false
    private var interactiveProgressHandler: ((CGFloat) -> Void)?
    private var currentInteractiveProgress: CGFloat = 0

    init(
        operation: UINavigationController.Operation,
        requestedStyle: ShellTransitionStyle,
        effectiveStyle: ShellTransitionStyle,
        spec: ShellTransitionSpec,
        interactiveSharedElementKeys: Set<String>? = nil,
        initiallyDegraded: Bool = false,
        onFallback: @escaping (ShellTransitionStyle, String) -> Void
    ) {
        self.operation = operation
        self.requestedStyle = requestedStyle
        self.effectiveStyle = effectiveStyle
        self.spec = spec
        self.interactiveSharedElementKeys = interactiveSharedElementKeys
        self.didFallback = initiallyDegraded
        self.onFallback = onFallback
        super.init()
    }

    func transitionDuration(
        using transitionContext: UIViewControllerContextTransitioning?
    ) -> TimeInterval {
        if effectiveStyle == .none { return 0.001 }
        let direction: ShellTransitionDirection = operation == .push ? .push : .pop
        let duration = spec.durationMilliseconds(for: direction)
        if UIAccessibility.isReduceMotionEnabled {
            return min(Double(duration) / 1_000, 0.15)
        }
        return Double(duration) / 1_000
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        interruptibleAnimator(using: transitionContext).startAnimation()
    }

    func interruptibleAnimator(
        using transitionContext: UIViewControllerContextTransitioning
    ) -> UIViewImplicitlyAnimating {
        if let propertyAnimator, activeContext === transitionContext {
            return propertyAnimator
        }

        guard let fromView = transitionContext.view(forKey: .from),
              let toView = transitionContext.view(forKey: .to),
              let fromController = transitionContext.viewController(forKey: .from),
              let toController = transitionContext.viewController(forKey: .to) else {
            let animator = UIViewPropertyAnimator(duration: 0, curve: .linear)
            animator.addCompletion { _ in transitionContext.completeTransition(false) }
            propertyAnimator = animator
            activeContext = transitionContext
            return animator
        }

        activeContext = transitionContext
        interactiveTransition = transitionContext.isInteractive
        let container = transitionContext.containerView
        let isPush = operation == .push
        let finalFrame = transitionContext.finalFrame(for: toController)
        if isPush {
            toView.frame = finalFrame
            container.addSubview(toView)
        } else {
            toView.frame = finalFrame
            container.insertSubview(toView, belowSubview: fromView)
        }
        container.layoutIfNeeded()
        fromController.view.layoutIfNeeded()
        toController.view.layoutIfNeeded()

        var plans: [AnimationPlan] = []
        var animatedFromView = fromView
        var outgoingSnapshot: UIView?
        if let source = fromController as? LynxContainerViewController,
           !source.request.transitionSpec.routeConfig.maintainState {
            if source.request.transitionSpec.routeConfig.allowExitRouteSnapshotting,
               isSnapshotSupported(fromView),
               let snapshot = fromView.snapshotView(afterScreenUpdates: false) {
                snapshot.frame = fromView.convert(fromView.bounds, to: container)
                outgoingSnapshot = snapshot
                animatedFromView = snapshot
            } else {
                // maintainState=false 不能伪装成已卸载；无法快照时保留 live view 并明确降级。
                fallBack(reason: "route_snapshot_unavailable")
            }
        }

        if effectiveStyle == .sharedElement {
            if let plan = makeSharedElementOverlay(
                from: fromController,
                to: toController,
                fromView: fromView,
                toView: toView,
                container: container,
                isPush: isPush
            ) {
                plans.append(plan)
            } else {
                fallBack(reason: "snapshot_unavailable")
            }
        } else if effectiveStyle == .openContainer {
            if let plan = makeOpenContainerOverlay(
                from: fromController,
                to: toController,
                fromView: fromView,
                toView: toView,
                container: container,
                isPush: isPush
            ) {
                plans.append(plan)
            } else {
                fallBack(reason: "snapshot_unavailable")
            }
        }

        if let outgoingSnapshot {
            let originalAlpha = fromView.alpha
            container.insertSubview(outgoingSnapshot, aboveSubview: fromView)
            fromView.alpha = 0
            plans.insert(
                AnimationPlan(
                    animate: {},
                    cleanup: {
                        fromView.alpha = originalAlpha
                        outgoingSnapshot.removeFromSuperview()
                    }
                ),
                at: 0
            )
        }

        var presetPlan: AnimationPlan?
        if let routeType = spec.routeType,
           !didFallback,
           effectiveStyle == spec.baseEffectiveStyle {
            if let failure = partialPresetFailureReason(
                routeType: routeType,
                from: fromController,
                to: toController,
                fromView: animatedFromView,
                isPush: isPush
            ) {
                fallBack(reason: failure)
            } else {
                presetPlan = makePresetPlan(
                    routeType: routeType,
                    from: fromController,
                    to: toController,
                    fromView: animatedFromView,
                    toView: toView,
                    container: container,
                    isPush: isPush
                )
                if presetPlan == nil {
                    fallBack(reason: "route_snapshot_unavailable")
                }
            }
        }
        if let presetPlan {
            plans.append(presetPlan)
        } else {
            prepareBaseViews(
                style: effectiveStyle,
                fromView: animatedFromView,
                toView: toView,
                container: container,
                isPush: isPush
            )
            plans.append(
                AnimationPlan(
                    animate: { [weak self, weak toView] in
                        guard let self, let toView else { return }
                        self.animateBaseViews(
                            style: self.effectiveStyle,
                            fromView: animatedFromView,
                            toView: toView,
                            isPush: isPush
                        )
                    },
                    cleanup: {}
                )
            )
        }

        cleanup = {
            plans.reversed().forEach { $0.cleanup() }
        }
        let timing: UITimingCurveProvider
        if spec.routeType == .bottomSheet, operation == .pop {
            // Page Sheet 关闭只沿 Y 轴离场，不使用 spring，避免越过终点后回弹抖动。
            timing = UICubicTimingParameters(animationCurve: .easeIn)
        } else {
            timing = UISpringTimingParameters(dampingRatio: 0.92)
        }
        let animator = UIViewPropertyAnimator(
            duration: transitionDuration(using: transitionContext),
            timingParameters: timing
        )
        animator.addAnimations {
            plans.forEach { $0.animate() }
        }
        animator.addCompletion { [weak self, weak fromView, weak toView] _ in
            guard let self else { return }
            let cancelled = transitionContext.transitionWasCancelled
            let preserveBottomSheetTerminalState = self.operation == .pop &&
                self.spec.routeType == .bottomSheet &&
                ShellBottomSheetMotion.preservesTerminalState(
                    transitionCancelled: cancelled
                )
            if !preserveBottomSheetTerminalState {
                fromView?.alpha = 1
                fromView?.transform = .identity
                fromView?.layer.cornerRadius = 0
                fromView?.clipsToBounds = false
                self.cleanup?()
            }
            toView?.alpha = 1
            toView?.transform = .identity
            toView?.layer.cornerRadius = 0
            toView?.clipsToBounds = false
            self.cleanup = nil
            self.completionFinalizer?(!cancelled)
            self.completionFinalizer = nil
            transitionContext.completeTransition(!cancelled)
        }
        propertyAnimator = animator
        return animator
    }

    func animationEnded(_ transitionCompleted: Bool) {
        cleanup?()
        cleanup = nil
        completionFinalizer = nil
        propertyAnimator = nil
        activeContext = nil
        interactiveProgressHandler = nil
        currentInteractiveProgress = 0
    }

    /** coordinator 的唯一手势进度入口；只更新 native overlay，不跨 Bridge。 */
    func updateInteractiveProgress(_ progress: CGFloat) {
        let normalized = min(max(progress, 0), 1)
        currentInteractiveProgress = normalized
        interactiveProgressHandler?(normalized)
    }

    /** UIPercentDrivenInteractiveTransition settle 时让 overlay 同步回到 0 或前进到 1。 */
    func settleInteractive(completed: Bool) {
        guard let handler = interactiveProgressHandler else { return }
        let target: CGFloat = completed ? 1 : 0
        let remaining = abs(target - currentInteractiveProgress)
        UIView.animate(
            withDuration: max(0.08, nativeAnimationDuration * Double(remaining)),
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut]
        ) {
            handler(target)
        }
        currentInteractiveProgress = target
    }

    private func fallBack(reason: String) {
        let fallback = spec.fallbackStyle
        didFallback = true
        effectiveStyle = fallback
        onFallback(fallback, reason)
    }

    private struct AnimationPlan {
        let animate: () -> Void
        let cleanup: () -> Void
    }

    /**
     * preset renderer 的单个可逆端点。
     *
     * Skyline 的公开生命周期要求 push 使用 0→1、pop 使用 1→0。所有页面级预设都
     * 只允许声明这两个端点，禁止再为 pop 另写一套“看起来相似”的动画参数。
     */
    private struct PresetViewState {
        let alpha: CGFloat
        let transform: CGAffineTransform
        /** nil 表示不改内容卡片自身的固定圆角。 */
        let cornerRadius: CGFloat?

        init(
            alpha: CGFloat = 1,
            transform: CGAffineTransform = .identity,
            cornerRadius: CGFloat? = nil
        ) {
            self.alpha = alpha
            self.transform = transform
            self.cornerRadius = cornerRadius
        }
    }

    private func applyPresetState(
        _ state: PresetViewState,
        to view: UIView,
        preserveClipping: Bool = false
    ) {
        view.alpha = state.alpha
        view.transform = state.transform
        guard let cornerRadius = state.cornerRadius else { return }
        view.layer.cornerCurve = .continuous
        view.layer.cornerRadius = cornerRadius
        view.clipsToBounds = preserveClipping || cornerRadius > 0
    }

    // MARK: - 基础壳动画

    private func prepareBaseViews(
        style: ShellTransitionStyle,
        fromView: UIView,
        toView: UIView,
        container: UIView,
        isPush: Bool
    ) {
        fromView.alpha = 1
        fromView.transform = .identity
        toView.alpha = 1
        toView.transform = .identity
        let width = max(container.bounds.width, 1)
        let height = max(container.bounds.height, 1)

        switch style {
        case .fade:
            // push 终态的上一页 alpha=0.78；pop 必须从同一终态反向恢复。
            toView.alpha = isPush ? 0 : 0.78
        case .sharedElement:
            // 页面淡入淡出由共享元素 overlay 的同一个 progress 驱动。
            // 这里不能再叠一层 UIViewPropertyAnimator，否则手势取消时会有双进度源。
            break
        case .openContainer:
            // 目标真实页面在扩张完成前保持隐藏，只能通过 clipHost 内的 snapshot 可见。
            if isPush {
                toView.alpha = 0
            } else {
                fromView.alpha = 0
                // 与 push 时来源页的最终暗化值严格对应。
                toView.alpha = 0.55
            }
        case .slide:
            toView.transform = CGAffineTransform(
                translationX: isPush ? width : -width * 0.28,
                y: 0
            )
        case .slideUp:
            toView.transform = isPush
                ? CGAffineTransform(translationX: 0, y: height)
                : CGAffineTransform(scaleX: 0.98, y: 0.98)
        case .zoom:
            toView.alpha = isPush ? 0 : 0.58
            toView.transform = isPush
                ? CGAffineTransform(scaleX: 0.9, y: 0.9)
                : CGAffineTransform(scaleX: 1.04, y: 1.04)
        case .default, .none:
            break
        }
    }

    private func animateBaseViews(
        style: ShellTransitionStyle,
        fromView: UIView,
        toView: UIView,
        isPush: Bool
    ) {
        switch style {
        case .fade:
            if isPush {
                fromView.alpha = 0.78
                toView.alpha = 1
            } else {
                fromView.alpha = 0
                toView.alpha = 1
            }
        case .sharedElement:
            // makeSharedElementOverlay 统一驱动页面与所有共享元素。
            break
        case .openContainer:
            if isPush {
                fromView.alpha = 0.55
                toView.alpha = 0
            } else {
                fromView.alpha = 0
                toView.alpha = 1
            }
        case .slide:
            if isPush {
                fromView.transform = CGAffineTransform(
                    translationX: -fromView.bounds.width * 0.28,
                    y: 0
                )
                toView.transform = .identity
            } else {
                fromView.transform = CGAffineTransform(
                    translationX: fromView.bounds.width,
                    y: 0
                )
                toView.transform = .identity
            }
        case .slideUp:
            if isPush {
                fromView.transform = CGAffineTransform(scaleX: 0.98, y: 0.98)
                toView.transform = .identity
            } else {
                fromView.transform = CGAffineTransform(
                    translationX: 0,
                    y: fromView.bounds.height
                )
                toView.transform = .identity
            }
        case .zoom:
            if isPush {
                fromView.alpha = 0.58
                fromView.transform = CGAffineTransform(scaleX: 1.04, y: 1.04)
                toView.alpha = 1
                toView.transform = .identity
            } else {
                fromView.alpha = 0
                fromView.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
                toView.alpha = 1
                toView.transform = .identity
            }
        case .default, .none:
            break
        }
    }

    // MARK: - 七种 preset-route renderer

    private func partialPresetFailureReason(
        routeType: ShellRouteType,
        from fromController: UIViewController,
        to toController: UIViewController,
        fromView: UIView,
        isPush: Bool
    ) -> String? {
        guard routeType.isPartialContainer else { return nil }
        let allowsExit = (
            fromController as? LynxContainerViewController
        )?.request.transitionSpec.routeConfig.allowExitRouteSnapshotting ?? true
        let allowsEnter = (
            toController as? LynxContainerViewController
        )?.request.transitionSpec.routeConfig.allowEnterRouteSnapshotting ?? true
        guard allowsExit, allowsEnter else {
            return "route_snapshot_disabled"
        }
        if isPush, !isSnapshotSupported(fromView) {
            return "route_snapshot_unavailable"
        }
        return nil
    }

    private func makePresetPlan(
        routeType: ShellRouteType,
        from fromController: UIViewController,
        to toController: UIViewController,
        fromView: UIView,
        toView: UIView,
        container: UIView,
        isPush: Bool
    ) -> AnimationPlan? {
        guard routeType != .heroSheet else { return nil }
        let fromLynx = fromController as? LynxContainerViewController
        let toLynx = toController as? LynxContainerViewController
        let fromContent = fromView === fromController.view
            ? (fromLynx?.transitionContentView ?? fromView)
            : fromView
        let toContent = toLynx?.transitionContentView ?? toView
        let fromBarrier = fromLynx?.transitionBarrierView
        let toBarrier = toLynx?.transitionBarrierView
        let fromBackdrop = fromLynx?.transitionBackdropContentView
        let width = max(container.bounds.width, 1)
        let height = max(container.bounds.height, 1)

        let movingContent = isPush ? toContent : fromContent
        let primaryDismissed: PresetViewState
        let secondaryPresented: PresetViewState
        switch routeType {
        case .bottomSheet:
            let dismissed = ShellBottomSheetMotion.state(progress: 0)
            let presented = ShellBottomSheetMotion.state(progress: 1)
            primaryDismissed = PresetViewState(
                transform: CGAffineTransform(
                    translationX: 0,
                    y: max(
                        movingContent.bounds.height,
                        height * spec.routeOptions.heightVH / 100
                    ) * dismissed.sheetTranslationFraction
                )
            )
            secondaryPresented = PresetViewState(
                transform: CGAffineTransform(
                    translationX: 0,
                    y: presented.backdropTranslationY
                ).scaledBy(
                    x: presented.backdropScale,
                    y: presented.backdropScale
                ),
                cornerRadius: presented.backdropCornerRadius
            )

        case .heroSheet:
            // heroSheet 的内容和关闭动画归 Lynx 页面；这里不再提供原生 renderer。
            return nil

        case .upwards:
            primaryDismissed = PresetViewState(
                transform: CGAffineTransform(translationX: 0, y: height)
            )
            secondaryPresented = PresetViewState(
                transform: CGAffineTransform(scaleX: 0.98, y: 0.98)
            )

        case .zoom:
            primaryDismissed = PresetViewState(
                alpha: 0,
                transform: CGAffineTransform(scaleX: 0.82, y: 0.82)
            )
            secondaryPresented = PresetViewState(
                alpha: 0.6,
                transform: CGAffineTransform(scaleX: 1.04, y: 1.04)
            )

        case .cupertinoModal:
            primaryDismissed = PresetViewState(
                alpha: 0,
                transform: CGAffineTransform(
                    translationX: 0,
                    y: 44
                ).scaledBy(x: 0.94, y: 0.94)
            )
            secondaryPresented = PresetViewState(
                transform: CGAffineTransform(
                    translationX: 0,
                    y: 12
                ).scaledBy(x: 0.93, y: 0.93),
                cornerRadius: 18
            )

        case .cupertinoModalInside:
            primaryDismissed = PresetViewState(
                transform: CGAffineTransform(
                    translationX: max(movingContent.bounds.width, width * 0.8),
                    y: 0
                )
            )
            secondaryPresented = PresetViewState(
                transform: CGAffineTransform(
                    translationX: -width * 0.24,
                    y: 0
                )
            )

        case .modalNavigation:
            primaryDismissed = PresetViewState(
                alpha: 0.92,
                transform: CGAffineTransform(
                    translationX: max(movingContent.bounds.width, width * 0.72),
                    y: 0
                ).scaledBy(x: 0.98, y: 0.98)
            )
            secondaryPresented = PresetViewState(
                transform: CGAffineTransform(
                    translationX: -width * 0.18,
                    y: 0
                )
            )

        case .modal:
            primaryDismissed = PresetViewState(
                alpha: 0,
                transform: CGAffineTransform(scaleX: 0.72, y: 0.72)
            )
            secondaryPresented = PresetViewState(
                transform: CGAffineTransform(scaleX: 0.97, y: 0.97)
            )
        }
        let primaryPresented = PresetViewState()
        let secondaryDismissed = PresetViewState(
            cornerRadius: secondaryPresented.cornerRadius.map { _ in 0 }
        )
        let primaryView = isPush
            ? (routeType.isPartialContainer ? toContent : toView)
            : (routeType.isPartialContainer ? fromContent : fromView)
        let secondaryView = isPush
            ? fromView
            : (routeType.isPartialContainer ? (fromBackdrop ?? toView) : toView)
        let barrierView = isPush ? toBarrier : fromBarrier

        if isPush, routeType.isPartialContainer {
            guard let target = toController as? LynxContainerViewController,
                  isSnapshotSupported(fromView),
                  let backdrop = fromView.snapshotView(afterScreenUpdates: false) else {
                return nil
            }
            backdrop.frame = target.view.bounds
            completionFinalizer = { [weak target] completed in
                guard completed, let target else {
                    backdrop.removeFromSuperview()
                    return
                }
                target.installTransitionBackdrop(
                    backdrop,
                    transform: secondaryPresented.transform,
                    cornerRadius: secondaryPresented.cornerRadius ?? 0
                )
            }
        } else if !isPush {
            completionFinalizer = { [weak self, weak secondaryView] completed in
                guard !completed, let self, let secondaryView else { return }
                // 手势取消后仍停留在 progress=1，背景必须回到进入后的同一终态。
                self.applyPresetState(
                    secondaryPresented,
                    to: secondaryView
                )
            }
        }

        [fromView, toView, fromContent, toContent].forEach {
            $0.alpha = 1
            $0.transform = .identity
        }
        fromBarrier?.alpha = 1
        toBarrier?.alpha = 1

        applyPresetState(
            isPush ? primaryDismissed : primaryPresented,
            to: primaryView
        )
        applyPresetState(
            isPush ? secondaryDismissed : secondaryPresented,
            to: secondaryView
        )
        barrierView?.alpha = isPush ? 0 : 1

        return AnimationPlan(
            animate: { [weak self] in
                guard let self else { return }
                self.applyPresetState(
                    isPush ? primaryPresented : primaryDismissed,
                    to: primaryView
                )
                self.applyPresetState(
                    isPush ? secondaryPresented : secondaryDismissed,
                    to: secondaryView,
                    preserveClipping:
                        !isPush && secondaryPresented.cornerRadius != nil
                )
                barrierView?.alpha = isPush ? 1 : 0
            },
            cleanup: {
                [fromView, toView, fromContent, toContent].forEach {
                    $0.alpha = 1
                    $0.transform = .identity
                }
                fromBarrier?.alpha = 1
                toBarrier?.alpha = 1
            }
        )
    }

    // MARK: - 多共享元素

    private struct SharedOverlayItem {
        let shadowHost: UIView
        let clipHost: UIView
        let snapshot: UIView
        let source: UIView
        let target: UIView
        let sourceAlpha: CGFloat
        let targetAlpha: CGFloat
        let startFrame: CGRect
        let endFrame: CGRect
        let startRadius: CGFloat
        let endRadius: CGFloat
        let startColor: UIColor?
        let endColor: UIColor?
        let startElevation: CGFloat
        let endElevation: CGFloat
        let tween: ShellRectTweenType
    }

    private func makeSharedElementOverlay(
        from fromController: UIViewController,
        to toController: UIViewController,
        fromView: UIView,
        toView: UIView,
        container: UIView,
        isPush: Bool
    ) -> AnimationPlan? {
        let descriptors = interactiveSharedElementKeys.map { keys in
            spec.sharedElements.filter { keys.contains($0.key) }
        } ?? spec.sharedElements
        guard !descriptors.isEmpty,
              let fromLynx = fromController as? LynxContainerViewController,
              let toLynx = toController as? LynxContainerViewController,
              fromLynx.request.transitionSpec.routeConfig.allowExitRouteSnapshotting,
              toLynx.request.transitionSpec.routeConfig.allowEnterRouteSnapshotting else {
            return nil
        }

        var items: [SharedOverlayItem] = []
        for descriptor in descriptors {
            let fromSelector = isPush
                ? descriptor.sourceSelector
                : descriptor.targetSelector
            let toSelector = isPush
                ? descriptor.targetSelector
                : descriptor.sourceSelector
            guard let source = fromLynx.resolveElement(idSelector: fromSelector),
                  let target = toLynx.resolveElement(idSelector: toSelector),
                  isSnapshotSupported(source),
                  isSnapshotSupported(target) else {
                items.forEach { restoreSharedItem($0) }
                return nil
            }

            let shuttle = isPush ? descriptor.shuttleOnPush : descriptor.shuttleOnPop
            let snapshotSource = shuttle == .from ? source : target
            guard let snapshot = snapshotSource.snapshotView(
                afterScreenUpdates: shuttle == .to
            ) else {
                items.forEach { restoreSharedItem($0) }
                return nil
            }
            let startFrame = source.convert(source.bounds, to: container)
            let endFrame = target.convert(target.bounds, to: container)
            guard isUsable(startFrame), isUsable(endFrame) else {
                items.forEach { restoreSharedItem($0) }
                return nil
            }

            let sourceAlpha = source.alpha
            let targetAlpha = target.alpha
            source.alpha = 0
            target.alpha = 0
            let startStyle = isPush ? descriptor.sourceStyle : descriptor.targetStyle
            let endStyle = isPush ? descriptor.targetStyle : descriptor.sourceStyle
            let startRadius = startStyle?.cornerRadius ?? source.layer.cornerRadius
            let endRadius = endStyle?.cornerRadius ?? target.layer.cornerRadius
            let startColor = startStyle?.backgroundColor.flatMap {
                UIColor(shellHex: $0)
            }
                ?? snapshot.backgroundColor
            let endColor = endStyle?.backgroundColor.flatMap {
                UIColor(shellHex: $0)
            }
                ?? target.backgroundColor
            let startElevation = startStyle?.elevation ?? source.layer.shadowRadius
            let endElevation = endStyle?.elevation ?? target.layer.shadowRadius
            let shadowHost = UIView(frame: startFrame)
            shadowHost.backgroundColor = .clear
            shadowHost.clipsToBounds = false
            shadowHost.layer.masksToBounds = false
            applyShadow(
                to: shadowHost.layer,
                elevation: startElevation
            )
            let clipHost = UIView(frame: shadowHost.bounds)
            clipHost.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            clipHost.clipsToBounds = true
            clipHost.layer.masksToBounds = true
            clipHost.layer.cornerCurve = .continuous
            clipHost.layer.cornerRadius = startRadius
            clipHost.backgroundColor = startColor
            snapshot.frame = clipHost.bounds
            snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            clipHost.addSubview(snapshot)
            shadowHost.addSubview(clipHost)
            // addSubview 的声明顺序天然保证后声明元素处于更高 overlay 层。
            container.addSubview(shadowHost)
            items.append(
                SharedOverlayItem(
                    shadowHost: shadowHost,
                    clipHost: clipHost,
                    snapshot: snapshot,
                    source: source,
                    target: target,
                    sourceAlpha: sourceAlpha,
                    targetAlpha: targetAlpha,
                    startFrame: startFrame,
                    endFrame: endFrame,
                    startRadius: startRadius,
                    endRadius: endRadius,
                    startColor: startColor,
                    endColor: endColor,
                    startElevation: startElevation,
                    endElevation: endElevation,
                    tween: descriptor.rectTweenType
                )
            )
        }

        let fromPageAlpha = fromView.alpha
        let toPageAlpha = toView.alpha
        let update: (CGFloat) -> Void = {
            [weak self, weak fromView, weak toView] rawProgress in
            guard let self, let fromView, let toView else { return }
            let progress = min(max(rawProgress, 0), 1)
            items.forEach { self.applySharedItem($0, progress: progress) }

            // Lynx view 默认允许节点扁平化。即使 ShareElement 已强制
            // flatten=false，页面级 fade-through 仍是必要的兜底：旧页面在
            // 前 35% 完全退出，新页面从 35% 开始进入，避免 live page 与
            // 原生 overlay 中的标题、价格、图片在中途形成双影。
            fromView.alpha = 1 - min(progress / 0.35, 1)
            toView.alpha = max((progress - 0.35) / 0.65, 0)
        }
        update(0)
        if interactiveTransition {
            interactiveProgressHandler = update
        }
        return AnimationPlan(
            animate: { [weak self] in
                guard let self else { return }
                if !self.interactiveTransition {
                    let steps = 24
                    UIView.animateKeyframes(
                        withDuration: self.nativeAnimationDuration,
                        delay: 0,
                        options: [.calculationModeLinear, .beginFromCurrentState]
                    ) {
                        for step in 1 ... steps {
                            let progress = CGFloat(step) / CGFloat(steps)
                            UIView.addKeyframe(
                                withRelativeStartTime: Double(step - 1) / Double(steps),
                                relativeDuration: 1 / Double(steps)
                            ) {
                                update(progress)
                            }
                        }
                    }
                }
            },
            cleanup: {
                fromView.alpha = fromPageAlpha
                toView.alpha = toPageAlpha
                items.forEach { self.restoreSharedItem($0) }
            }
        )
    }

    private func applySharedItem(_ item: SharedOverlayItem, progress: CGFloat) {
        item.shadowHost.frame = rect(
            from: item.startFrame,
            to: item.endFrame,
            rawProgress: progress,
            tween: item.tween
        )
        item.clipHost.frame = item.shadowHost.bounds
        item.clipHost.layer.cornerRadius = max(
            0,
            interpolate(
                item.startRadius,
                item.endRadius,
                progress: curveProgress(progress, tween: item.tween)
            )
        )
        let eased = min(max(curveProgress(progress, tween: item.tween), 0), 1)
        item.clipHost.backgroundColor = interpolateColor(
            from: item.startColor,
            to: item.endColor,
            progress: eased
        )
        applyShadow(
            to: item.shadowHost.layer,
            elevation: interpolate(
                item.startElevation,
                item.endElevation,
                progress: eased
            )
        )
    }

    private func restoreSharedItem(_ item: SharedOverlayItem) {
        item.source.alpha = item.sourceAlpha
        item.target.alpha = item.targetAlpha
        item.shadowHost.removeFromSuperview()
    }

    // MARK: - Open Container

    private func makeOpenContainerOverlay(
        from fromController: UIViewController,
        to toController: UIViewController,
        fromView: UIView,
        toView: UIView,
        container: UIView,
        isPush: Bool
    ) -> AnimationPlan? {
        guard let descriptor = spec.openContainer else { return nil }
        let fromAllowsSnapshot = (
            fromController as? LynxContainerViewController
        )?.request.transitionSpec.routeConfig.allowExitRouteSnapshotting ?? true
        let toAllowsSnapshot = (
            toController as? LynxContainerViewController
        )?.request.transitionSpec.routeConfig.allowEnterRouteSnapshotting ?? true
        guard fromAllowsSnapshot, toAllowsSnapshot else { return nil }
        let cardController = isPush ? fromController : toController
        guard let cardLynx = cardController as? LynxContainerViewController,
              let card = cardLynx.resolveElement(idSelector: descriptor.sourceSelector),
              isSnapshotSupported(card) else {
            return nil
        }

        let contentController = isPush ? toController : fromController
        let contentView = (contentController as? LynxContainerViewController)?
            .transitionContentView ?? (isPush ? toView : fromView)
        guard isSnapshotSupported(contentView),
              let cardSnapshot = card.snapshotView(afterScreenUpdates: !isPush),
              let pageSnapshot = contentView.snapshotView(afterScreenUpdates: isPush) else {
            return nil
        }

        let cardFrame = card.convert(card.bounds, to: container)
        let pageFrame = contentView.convert(contentView.bounds, to: container)
        let startFrame = isPush ? cardFrame : pageFrame
        let endFrame = isPush ? pageFrame : cardFrame
        guard isUsable(startFrame), isUsable(endFrame) else { return nil }

        let cardAlpha = card.alpha
        let fromAlpha = fromView.alpha
        let toAlpha = toView.alpha
        card.alpha = 0
        if isPush {
            toView.alpha = 0
        } else {
            fromView.alpha = 0
        }

        // 外层只负责 shadow，绝不裁剪；内层只负责圆角和内容裁剪。
        let shadowHost = UIView(frame: startFrame)
        shadowHost.backgroundColor = .clear
        shadowHost.clipsToBounds = false
        shadowHost.layer.masksToBounds = false
        applyShadow(
            to: shadowHost.layer,
            elevation: isPush
                ? descriptor.closedElevation
                : descriptor.openElevation
        )

        let clipHost = UIView(frame: shadowHost.bounds)
        clipHost.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        clipHost.clipsToBounds = true
        clipHost.layer.masksToBounds = true
        clipHost.layer.cornerCurve = .continuous
        clipHost.layer.cornerRadius = isPush
            ? descriptor.closedCornerRadius
            : descriptor.openCornerRadius
        let startColor = UIColor(
            shellHex: isPush ? descriptor.closedColor : descriptor.openColor
        )
        let middleColor = descriptor.middleColor.flatMap {
            UIColor(shellHex: $0)
        }
        let finalColor = UIColor(
            shellHex: isPush ? descriptor.openColor : descriptor.closedColor
        )
        clipHost.backgroundColor = startColor

        let outgoing = isPush ? cardSnapshot : pageSnapshot
        let incoming = isPush ? pageSnapshot : cardSnapshot
        outgoing.frame = clipHost.bounds
        incoming.frame = clipHost.bounds
        outgoing.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        incoming.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        outgoing.alpha = 1
        incoming.alpha = 0
        clipHost.addSubview(outgoing)
        clipHost.addSubview(incoming)
        shadowHost.addSubview(clipHost)
        container.addSubview(shadowHost)

        let startRadius = isPush
            ? descriptor.closedCornerRadius
            : descriptor.openCornerRadius
        let finalRadius = isPush
            ? descriptor.openCornerRadius
            : descriptor.closedCornerRadius
        let startElevation = isPush
            ? descriptor.closedElevation
            : descriptor.openElevation
        let finalElevation = isPush
            ? descriptor.openElevation
            : descriptor.closedElevation
        let update: (CGFloat) -> Void = { [weak self] rawProgress in
            guard let self else { return }
            let progress = min(max(rawProgress, 0), 1)
            let eased = self.easeInOut(progress)
            shadowHost.frame = self.rect(
                from: startFrame,
                to: endFrame,
                rawProgress: progress,
                tween: .materialRectArc
            )
            clipHost.frame = shadowHost.bounds
            clipHost.layer.cornerRadius = self.interpolate(
                startRadius,
                finalRadius,
                progress: eased
            )
            self.applyShadow(
                to: shadowHost.layer,
                elevation: self.interpolate(
                    startElevation,
                    finalElevation,
                    progress: eased
                )
            )
            if let middleColor {
                if progress < 0.5 {
                    clipHost.backgroundColor = self.interpolateColor(
                        from: startColor,
                        to: middleColor,
                        progress: progress * 2
                    )
                } else {
                    clipHost.backgroundColor = self.interpolateColor(
                        from: middleColor,
                        to: finalColor,
                        progress: (progress - 0.5) * 2
                    )
                }
            } else {
                clipHost.backgroundColor = self.interpolateColor(
                    from: startColor,
                    to: finalColor,
                    progress: progress
                )
            }
            switch descriptor.transitionType {
            case .fade:
                outgoing.alpha = 1 - progress
                incoming.alpha = progress
            case .fadeThrough:
                outgoing.alpha = 1 - min(progress / 0.35, 1)
                // 与 Android 及 Skyline 公开语义保持一致：旧内容在前 35%
                // 完全淡出，随后新内容从 35% 开始淡入。这样只有一个明确
                // 的切换点，不会在 35%～65% 之间留下无内容的黑场。
                incoming.alpha = max((progress - 0.35) / 0.65, 0)
            }
        }

        if interactiveTransition {
            interactiveProgressHandler = update
        }

        return AnimationPlan(
            animate: { [weak self] in
                guard let self else { return }
                if !self.interactiveTransition {
                    let steps = 24
                    UIView.animateKeyframes(
                        withDuration: self.nativeAnimationDuration,
                        delay: 0,
                        options: [.calculationModeLinear, .beginFromCurrentState]
                    ) {
                        for step in 1 ... steps {
                            let progress = CGFloat(step) / CGFloat(steps)
                            UIView.addKeyframe(
                                withRelativeStartTime: Double(step - 1) / Double(steps),
                                relativeDuration: 1 / Double(steps)
                            ) {
                                update(progress)
                            }
                        }
                    }
                }
            },
            cleanup: {
                card.alpha = cardAlpha
                fromView.alpha = fromAlpha
                toView.alpha = toAlpha
                shadowHost.removeFromSuperview()
            }
        )
    }

    // MARK: - Native rect tween

    private func rect(
        from start: CGRect,
        to end: CGRect,
        rawProgress: CGFloat,
        tween: ShellRectTweenType
    ) -> CGRect {
        let t = curveProgress(rawProgress, tween: tween)
        let center: CGPoint
        switch tween {
        case .materialRectArc:
            let control = CGPoint(x: end.midX, y: start.midY)
            center = quadraticPoint(
                from: CGPoint(x: start.midX, y: start.midY),
                control: control,
                to: CGPoint(x: end.midX, y: end.midY),
                progress: min(max(rawProgress, 0), 1)
            )
        case .materialRectCenterArc:
            let startCenter = CGPoint(x: start.midX, y: start.midY)
            let endCenter = CGPoint(x: end.midX, y: end.midY)
            let dx = endCenter.x - startCenter.x
            let dy = endCenter.y - startCenter.y
            let control = CGPoint(
                x: (startCenter.x + endCenter.x) / 2 - dy * 0.22,
                y: (startCenter.y + endCenter.y) / 2 + dx * 0.22
            )
            center = quadraticPoint(
                from: startCenter,
                control: control,
                to: endCenter,
                progress: min(max(rawProgress, 0), 1)
            )
        default:
            center = CGPoint(
                x: interpolate(start.midX, end.midX, progress: t),
                y: interpolate(start.midY, end.midY, progress: t)
            )
        }
        let sizeProgress = tween == .materialRectArc || tween == .materialRectCenterArc
            ? easeInOut(min(max(rawProgress, 0), 1))
            : t
        let width = max(0.5, interpolate(start.width, end.width, progress: sizeProgress))
        let height = max(0.5, interpolate(start.height, end.height, progress: sizeProgress))
        return CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )
    }

    private func curveProgress(
        _ rawProgress: CGFloat,
        tween: ShellRectTweenType
    ) -> CGFloat {
        let t = min(max(rawProgress, 0), 1)
        switch tween {
        case .linear:
            return t
        case .materialRectArc, .materialRectCenterArc:
            return easeInOut(t)
        case .elasticIn:
            return elasticIn(t)
        case .elasticOut:
            return 1 - elasticIn(1 - t)
        case .elasticInOut:
            return t < 0.5
                ? elasticIn(t * 2) / 2
                : 1 - elasticIn((1 - t) * 2) / 2
        case .bounceIn:
            return 1 - bounceOut(1 - t)
        case .bounceOut:
            return bounceOut(t)
        case .bounceInOut:
            return t < 0.5
                ? (1 - bounceOut(1 - 2 * t)) / 2
                : (1 + bounceOut(2 * t - 1)) / 2
        case let .cubicBezier(x1, y1, x2, y2):
            return cubicBezierProgress(
                x: t,
                x1: x1,
                y1: y1,
                x2: x2,
                y2: y2
            )
        }
    }

    private func interpolate(_ start: CGFloat, _ end: CGFloat, progress: CGFloat) -> CGFloat {
        start + (end - start) * progress
    }

    private func interpolateColor(
        from start: UIColor?,
        to end: UIColor?,
        progress: CGFloat
    ) -> UIColor? {
        guard let start, let end else { return end ?? start }
        var sr: CGFloat = 0
        var sg: CGFloat = 0
        var sb: CGFloat = 0
        var sa: CGFloat = 0
        var er: CGFloat = 0
        var eg: CGFloat = 0
        var eb: CGFloat = 0
        var ea: CGFloat = 0
        guard start.getRed(&sr, green: &sg, blue: &sb, alpha: &sa),
              end.getRed(&er, green: &eg, blue: &eb, alpha: &ea) else {
            return progress < 0.5 ? start : end
        }
        let value = min(max(progress, 0), 1)
        return UIColor(
            red: interpolate(sr, er, progress: value),
            green: interpolate(sg, eg, progress: value),
            blue: interpolate(sb, eb, progress: value),
            alpha: interpolate(sa, ea, progress: value)
        )
    }

    private func quadraticPoint(
        from start: CGPoint,
        control: CGPoint,
        to end: CGPoint,
        progress: CGFloat
    ) -> CGPoint {
        let inverse = 1 - progress
        return CGPoint(
            x: inverse * inverse * start.x
                + 2 * inverse * progress * control.x
                + progress * progress * end.x,
            y: inverse * inverse * start.y
                + 2 * inverse * progress * control.y
                + progress * progress * end.y
        )
    }

    private func easeInOut(_ t: CGFloat) -> CGFloat {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }

    private func elasticIn(_ t: CGFloat) -> CGFloat {
        if t == 0 || t == 1 { return t }
        let period = (2 * CGFloat.pi) / 3
        return -pow(2, 10 * t - 10) * sin((t * 10 - 10.75) * period)
    }

    private func bounceOut(_ t: CGFloat) -> CGFloat {
        let n: CGFloat = 7.5625
        let d: CGFloat = 2.75
        if t < 1 / d {
            return n * t * t
        }
        if t < 2 / d {
            let value = t - 1.5 / d
            return n * value * value + 0.75
        }
        if t < 2.5 / d {
            let value = t - 2.25 / d
            return n * value * value + 0.9375
        }
        let value = t - 2.625 / d
        return n * value * value + 0.984375
    }

    private func cubicBezierProgress(
        x: CGFloat,
        x1: CGFloat,
        y1: CGFloat,
        x2: CGFloat,
        y2: CGFloat
    ) -> CGFloat {
        var low: CGFloat = 0
        var high: CGFloat = 1
        var parameter = x
        // 二分反解 Bezier x，避免极端控制点让 Newton 导数接近 0。
        for _ in 0 ..< 14 {
            parameter = (low + high) / 2
            let sampledX = cubicBezierCoordinate(parameter, first: x1, second: x2)
            if sampledX < x {
                low = parameter
            } else {
                high = parameter
            }
        }
        return cubicBezierCoordinate(parameter, first: y1, second: y2)
    }

    private func cubicBezierCoordinate(
        _ t: CGFloat,
        first: CGFloat,
        second: CGFloat
    ) -> CGFloat {
        let inverse = 1 - t
        return 3 * inverse * inverse * t * first
            + 3 * inverse * t * t * second
            + t * t * t
    }

    /** 共享元素/Open Container 与页面转场严格使用同一方向时长。 */
    private var nativeAnimationDuration: TimeInterval {
        let direction: ShellTransitionDirection = operation == .push ? .push : .pop
        let duration = Double(spec.durationMilliseconds(for: direction)) / 1_000
        if UIAccessibility.isReduceMotionEnabled {
            return max(0.001, min(duration, 0.15))
        }
        return max(0.001, duration)
    }

    // MARK: - Snapshot safeguards

    private func applyShadow(to layer: CALayer, elevation: CGFloat) {
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = elevation > 0 ? min(Float(elevation / 40), 0.28) : 0
        layer.shadowRadius = elevation
        layer.shadowOffset = CGSize(width: 0, height: max(1, elevation / 3))
    }

    private func isUsable(_ rect: CGRect) -> Bool {
        rect.isFinite && rect.width > 0.5 && rect.height > 0.5
    }

    private func isSnapshotSupported(_ view: UIView) -> Bool {
        guard !containsUnsupportedSurface(view) else { return false }
        var current: UIView? = view
        while let candidate = current {
            if isUnsupportedClass(candidate) { return false }
            current = candidate.superview
            if current === view.window { break }
        }
        return true
    }

    private func containsUnsupportedSurface(_ view: UIView) -> Bool {
        if isUnsupportedClass(view) { return true }
        return view.subviews.contains(where: containsUnsupportedSurface)
    }

    private func isUnsupportedClass(_ view: UIView) -> Bool {
        let name = NSStringFromClass(type(of: view))
        return name.contains("WKWebView") ||
            name.contains("MTKView") ||
            name.contains("AVPlayer") ||
            name.contains("Video")
    }
}

private extension CGRect {
    var isFinite: Bool {
        [origin.x, origin.y, size.width, size.height].allSatisfy(\.isFinite)
    }
}
