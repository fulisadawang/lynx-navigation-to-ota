import Foundation
import UIKit

/** Android、iOS 共用的原生容器转场类型。 */
enum ShellTransitionStyle: String, CaseIterable {
    case `default`
    case fade
    case slide
    case slideUp
    case zoom
    case sharedElement
    case openContainer
    case none
}

/** 原生转场方向；写入 globalProps 和诊断状态。 */
enum ShellTransitionDirection: String {
    case push
    case pop
}

/**
 * Skyline preset-route 的官方预设与壳扩展 heroSheet。
 *
 * routeType 不再折叠成一个近似 style：style 仅用于状态诊断与兜底，真实渲染器由
 * routeType 逐项选择，确保返回时仍进入同一原生 renderer。
 */
enum ShellRouteType: String, CaseIterable {
    case bottomSheet = "wx://bottom-sheet"
    case heroSheet = "wx://hero-sheet"
    case upwards = "wx://upwards"
    case zoom = "wx://zoom"
    case cupertinoModal = "wx://cupertino-modal"
    case cupertinoModalInside = "wx://cupertino-modal-inside"
    case modalNavigation = "wx://modal-navigation"
    case modal = "wx://modal"

    var diagnosticStyle: ShellTransitionStyle {
        switch self {
        case .bottomSheet, .heroSheet, .upwards:
            return .slideUp
        case .zoom, .cupertinoModal, .modal:
            return .zoom
        case .cupertinoModalInside, .modalNavigation:
            return .slide
        }
    }

    var isPartialContainer: Bool {
        switch self {
        case .bottomSheet, .heroSheet, .cupertinoModal, .cupertinoModalInside,
             .modalNavigation, .modal:
            return true
        case .upwards, .zoom:
            return false
        }
    }

    var isSheet: Bool {
        self == .bottomSheet || self == .heroSheet
    }
}

/** preset-route 的路由级配置；可选字段保留“未声明”和显式 false 的区别。 */
struct ShellRouteConfig {
    let transitionDurationMilliseconds: Int?
    let reverseTransitionDurationMilliseconds: Int?
    let opaque: Bool?
    let maintainState: Bool
    let barrierColor: String?
    let barrierDismissible: Bool?
    let barrierLabel: String?
    let canTransitionTo: Bool
    let canTransitionFrom: Bool
    let allowEnterRouteSnapshotting: Bool
    let allowExitRouteSnapshotting: Bool
    let fullscreenDrag: Bool?
    let popGestureDirection: ShellPopGestureSpec.Direction?

    static let `default` = ShellRouteConfig(
        transitionDurationMilliseconds: nil,
        reverseTransitionDurationMilliseconds: nil,
        opaque: nil,
        maintainState: true,
        barrierColor: nil,
        barrierDismissible: nil,
        barrierLabel: nil,
        canTransitionTo: true,
        canTransitionFrom: true,
        allowEnterRouteSnapshotting: true,
        allowExitRouteSnapshotting: true,
        fullscreenDrag: nil,
        popGestureDirection: nil
    )

    var dictionary: [String: Any] {
        var value: [String: Any] = [
            "canTransitionTo": canTransitionTo,
            "canTransitionFrom": canTransitionFrom,
            "maintainState": maintainState,
            "allowEnterRouteSnapshotting": allowEnterRouteSnapshotting,
            "allowExitRouteSnapshotting": allowExitRouteSnapshotting,
        ]
        if let transitionDurationMilliseconds {
            value["transitionDuration"] = transitionDurationMilliseconds
        }
        if let reverseTransitionDurationMilliseconds {
            value["reverseTransitionDuration"] = reverseTransitionDurationMilliseconds
        }
        if let opaque { value["opaque"] = opaque }
        if let barrierColor { value["barrierColor"] = barrierColor }
        if let barrierDismissible { value["barrierDismissible"] = barrierDismissible }
        if let barrierLabel { value["barrierLabel"] = barrierLabel }
        if let fullscreenDrag { value["fullscreenDrag"] = fullscreenDrag }
        if let popGestureDirection {
            value["popGestureDirection"] = popGestureDirection.rawValue
        }
        return value
    }

    static func fromDictionary(_ value: [String: Any]) -> ShellRouteConfig {
        ShellRouteConfig(
            transitionDurationMilliseconds: number(value["transitionDuration"])?.intValue,
            reverseTransitionDurationMilliseconds:
                number(value["reverseTransitionDuration"])?.intValue,
            opaque: bool(value["opaque"]),
            maintainState: bool(value["maintainState"]) ?? true,
            barrierColor: value["barrierColor"] as? String,
            barrierDismissible: bool(value["barrierDismissible"]),
            barrierLabel: value["barrierLabel"] as? String,
            canTransitionTo: bool(value["canTransitionTo"]) ?? true,
            canTransitionFrom: bool(value["canTransitionFrom"]) ?? true,
            allowEnterRouteSnapshotting:
                bool(value["allowEnterRouteSnapshotting"]) ?? true,
            allowExitRouteSnapshotting:
                bool(value["allowExitRouteSnapshotting"]) ?? true,
            fullscreenDrag: bool(value["fullscreenDrag"]),
            popGestureDirection: (value["popGestureDirection"] as? String).flatMap(
                ShellPopGestureSpec.Direction.init(rawValue:)
            )
        )
    }

    /** 顶层 transparent/heroSheet 只改变宿主承载透明度，不覆盖其它 routeConfig。 */
    func transparentized() -> ShellRouteConfig {
        ShellRouteConfig(
            transitionDurationMilliseconds: transitionDurationMilliseconds,
            reverseTransitionDurationMilliseconds: reverseTransitionDurationMilliseconds,
            opaque: false,
            maintainState: maintainState,
            barrierColor: barrierColor,
            barrierDismissible: barrierDismissible,
            barrierLabel: barrierLabel,
            canTransitionTo: canTransitionTo,
            canTransitionFrom: canTransitionFrom,
            allowEnterRouteSnapshotting: allowEnterRouteSnapshotting,
            allowExitRouteSnapshotting: allowExitRouteSnapshotting,
            fullscreenDrag: fullscreenDrag,
            popGestureDirection: popGestureDirection
        )
    }
}

/** Sheet 布局参数；height 使用 Skyline 的 vh 语义，detents 按升序排列。 */
struct ShellRouteOptions {
    let round: Bool
    let heightVH: CGFloat
    let detentsVH: [CGFloat]
    let initialDetentVH: CGFloat
    let initialDetentIndex: Int

    static let `default` = ShellRouteOptions(
        round: true,
        heightVH: ShellBottomSheetMotion.defaultHeightVH,
        detentsVH: [ShellBottomSheetMotion.defaultHeightVH],
        initialDetentVH: ShellBottomSheetMotion.defaultHeightVH,
        initialDetentIndex: 0
    )

    static let heroDefault = ShellRouteOptions(
        round: true,
        heightVH: ShellHeroSheetMotion.defaultInitialDetentVH,
        detentsVH: ShellHeroSheetMotion.defaultDetentsVH,
        initialDetentVH: ShellHeroSheetMotion.defaultInitialDetentVH,
        initialDetentIndex: ShellHeroSheetMotion.nearestDetentIndex(
            heightVH: ShellHeroSheetMotion.defaultInitialDetentVH,
            detentsVH: ShellHeroSheetMotion.defaultDetentsVH
        )
    )

    var dictionary: [String: Any] {
        [
            "round": round,
            "height": Double(heightVH),
            "detents": detentsVH.map { Double($0) },
            "initialDetent": Double(initialDetentVH),
        ]
    }

    static func fromDictionary(
        _ value: [String: Any],
        routeType: ShellRouteType? = nil
    ) -> ShellRouteOptions {
        let fallback = routeType == .heroSheet ? heroDefault : `default`
        let explicitHeight = number(value["height"]).map { CGFloat(truncating: $0) }
        let rawDetents = (value["detents"] as? [Any])?.compactMap {
            number($0).map { CGFloat(truncating: $0) }
        }
        let sortedDetents = rawDetents?.filter { $0 > 0 && $0 <= 100 }
            .sorted()
            .reduce(into: [CGFloat]()) { result, value in
                if result.last != value { result.append(value) }
            }
        let detents = sortedDetents?.isEmpty == false
            ? sortedDetents!
            : (explicitHeight.map { [$0] } ?? fallback.detentsVH)
        let requestedInitial = number(value["initialDetent"]).map {
            CGFloat(truncating: $0)
        } ?? explicitHeight ?? fallback.initialDetentVH
        let initialIndex = ShellHeroSheetMotion.nearestDetentIndex(
            heightVH: requestedInitial,
            detentsVH: detents
        )
        let initial = detents[initialIndex]
        return ShellRouteOptions(
            round: bool(value["round"]) ?? true,
            heightVH: initial,
            detentsVH: detents,
            initialDetentVH: initial,
            initialDetentIndex: initialIndex
        )
    }
}

/** 共享元素端点的可选视觉参数。 */
struct ShellRectStyle {
    let backgroundColor: String?
    let cornerRadius: CGFloat?
    let elevation: CGFloat?

    var dictionary: [String: Any] {
        var value: [String: Any] = [:]
        if let backgroundColor { value["backgroundColor"] = backgroundColor }
        if let cornerRadius { value["cornerRadius"] = Double(cornerRadius) }
        if let elevation { value["elevation"] = Double(elevation) }
        return value
    }

    static func fromDictionary(_ value: [String: Any]) -> ShellRectStyle {
        ShellRectStyle(
            backgroundColor: value["backgroundColor"] as? String,
            cornerRadius: number(value["cornerRadius"]).map { CGFloat(truncating: $0) },
            elevation: number(value["elevation"]).map { CGFloat(truncating: $0) }
        )
    }
}

/** 共享元素动画使用 from 端还是 to 端生成 shuttle snapshot。 */
enum ShellSharedElementShuttle: String {
    case from
    case to
}

/**
 * Skyline rectTweenType 的完整本地表示。
 *
 * Worklet on-frame 无法在 Module-only 架构中同步回调 JS，因此所有曲线都在 UIKit
 * 主线程以原生采样执行；不会逐帧跨 Bridge。
 */
enum ShellRectTweenType: Equatable {
    case linear
    case materialRectArc
    case materialRectCenterArc
    case elasticIn
    case elasticOut
    case elasticInOut
    case bounceIn
    case bounceOut
    case bounceInOut
    case cubicBezier(CGFloat, CGFloat, CGFloat, CGFloat)

    var wireName: String {
        switch self {
        case .linear: return "linear"
        case .materialRectArc: return "materialRectArc"
        case .materialRectCenterArc: return "materialRectCenterArc"
        case .elasticIn: return "elasticIn"
        case .elasticOut: return "elasticOut"
        case .elasticInOut: return "elasticInOut"
        case .bounceIn: return "bounceIn"
        case .bounceOut: return "bounceOut"
        case .bounceInOut: return "bounceInOut"
        case let .cubicBezier(x1, y1, x2, y2):
            return "cubic-bezier(\(x1),\(y1),\(x2),\(y2))"
        }
    }

    static func parse(_ rawValue: String) -> ShellRectTweenType? {
        switch rawValue {
        case "linear": return .linear
        case "materialRectArc": return .materialRectArc
        case "materialRectCenterArc": return .materialRectCenterArc
        case "elasticIn": return .elasticIn
        case "elasticOut": return .elasticOut
        case "elasticInOut": return .elasticInOut
        case "bounceIn": return .bounceIn
        case "bounceOut": return .bounceOut
        case "bounceInOut": return .bounceInOut
        default:
            guard rawValue.hasPrefix("cubic-bezier("), rawValue.hasSuffix(")") else {
                return nil
            }
            let start = rawValue.index(rawValue.startIndex, offsetBy: 13)
            let end = rawValue.index(before: rawValue.endIndex)
            let values = rawValue[start..<end]
                .split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard values.count == 4,
                  (0 ... 1).contains(values[0]),
                  (0 ... 1).contains(values[2]),
                  values[1].isFinite,
                  values[3].isFinite else {
                return nil
            }
            return .cubicBezier(
                CGFloat(values[0]),
                CGFloat(values[1]),
                CGFloat(values[2]),
                CGFloat(values[3])
            )
        }
    }
}

/** 跨两个真实 UIViewController 的共享元素描述。 */
struct ShellSharedElementSpec {
    let key: String
    let sourceSelector: String
    let targetSelector: String
    let transitionOnGesture: Bool
    let shuttleOnPush: ShellSharedElementShuttle
    let shuttleOnPop: ShellSharedElementShuttle
    let rectTweenType: ShellRectTweenType
    let sourceStyle: ShellRectStyle?
    let targetStyle: ShellRectStyle?

    var dictionary: [String: Any] {
        var value: [String: Any] = [
            "key": key,
            "sourceSelector": sourceSelector,
            "targetSelector": targetSelector,
            "transitionOnGesture": transitionOnGesture,
            "shuttleOnPush": shuttleOnPush.rawValue,
            "shuttleOnPop": shuttleOnPop.rawValue,
            "rectTweenType": rectTweenType.wireName,
        ]
        if let sourceStyle { value["sourceStyle"] = sourceStyle.dictionary }
        if let targetStyle { value["targetStyle"] = targetStyle.dictionary }
        return value
    }

    static func fromDictionary(_ value: [String: Any]) -> ShellSharedElementSpec? {
        guard let key = value["key"] as? String,
              let sourceSelector = value["sourceSelector"] as? String,
              let targetSelector = value["targetSelector"] as? String else {
            return nil
        }
        return ShellSharedElementSpec(
            key: key,
            sourceSelector: sourceSelector,
            targetSelector: targetSelector,
            transitionOnGesture: bool(value["transitionOnGesture"]) ?? false,
            shuttleOnPush: ShellSharedElementShuttle(
                rawValue: value["shuttleOnPush"] as? String ?? ""
            ) ?? .to,
            shuttleOnPop: ShellSharedElementShuttle(
                rawValue: value["shuttleOnPop"] as? String ?? ""
            ) ?? .to,
            rectTweenType: ShellRectTweenType.parse(
                value["rectTweenType"] as? String ?? ""
            ) ?? .materialRectArc,
            sourceStyle: (value["sourceStyle"] as? [String: Any]).map(
                ShellRectStyle.fromDictionary
            ),
            targetStyle: (value["targetStyle"] as? [String: Any]).map(
                ShellRectStyle.fromDictionary
            )
        )
    }
}

/** open-container 从关闭态卡片到整页容器的插值参数。 */
struct ShellOpenContainerSpec {
    enum TransitionType: String {
        case fade
        case fadeThrough
    }

    let sourceSelector: String
    let closedColor: String
    let middleColor: String?
    let openColor: String
    let closedCornerRadius: CGFloat
    let openCornerRadius: CGFloat
    let closedElevation: CGFloat
    let openElevation: CGFloat
    let transitionType: TransitionType
    let transitionDurationMilliseconds: Int

    var dictionary: [String: Any] {
        var value: [String: Any] = [
            "sourceSelector": sourceSelector,
            "closedColor": closedColor,
            "openColor": openColor,
            "closedCornerRadius": Double(closedCornerRadius),
            "openCornerRadius": Double(openCornerRadius),
            "closedElevation": Double(closedElevation),
            "openElevation": Double(openElevation),
            "transitionType": transitionType.rawValue,
            // 兼容旧壳字段；新调用优先使用 transitionType。
            "contentTransition": transitionType.rawValue,
            "transitionDuration": transitionDurationMilliseconds,
        ]
        if let middleColor, !middleColor.isEmpty {
            value["middleColor"] = middleColor
        }
        return value
    }

    static func fromDictionary(_ value: [String: Any]) -> ShellOpenContainerSpec? {
        guard let sourceSelector = value["sourceSelector"] as? String else { return nil }
        let transitionName = value["transitionType"] as? String
            ?? value["contentTransition"] as? String
            ?? "fade"
        return ShellOpenContainerSpec(
            sourceSelector: sourceSelector,
            closedColor: value["closedColor"] as? String ?? "white",
            middleColor: (value["middleColor"] as? String).flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
            },
            openColor: value["openColor"] as? String ?? "white",
            closedCornerRadius: number(value["closedCornerRadius"])
                .map { CGFloat(truncating: $0) } ?? 0,
            openCornerRadius: number(value["openCornerRadius"])
                .map { CGFloat(truncating: $0) } ?? 0,
            closedElevation: number(value["closedElevation"])
                .map { CGFloat(truncating: $0) } ?? 0,
            openElevation: number(value["openElevation"])
                .map { CGFloat(truncating: $0) } ?? 0,
            transitionType: TransitionType(rawValue: transitionName) ?? .fade,
            transitionDurationMilliseconds:
                number(value["transitionDuration"])?.intValue ?? 300
        )
    }
}

/** 返回手势声明；horizontal、vertical、multi 和全屏拖动均由壳原生手势执行。 */
struct ShellPopGestureSpec {
    enum Direction: String {
        case horizontal
        case vertical
        case multi
    }

    let enabled: Bool
    let direction: Direction
    let fullScreen: Bool
    let edgeWidth: CGFloat

    static let `default` = ShellPopGestureSpec(
        enabled: true,
        direction: .horizontal,
        fullScreen: false,
        edgeWidth: 28
    )

    var dictionary: [String: Any] {
        [
            "enabled": enabled,
            "direction": direction.rawValue,
            "fullScreen": fullScreen,
            "edgeWidth": Double(edgeWidth),
        ]
    }

    static func fromDictionary(_ value: [String: Any]) -> ShellPopGestureSpec {
        ShellPopGestureSpec(
            enabled: bool(value["enabled"]) ?? true,
            direction: Direction(rawValue: value["direction"] as? String ?? "") ?? .horizontal,
            fullScreen: bool(value["fullScreen"]) ?? false,
            edgeWidth: number(value["edgeWidth"]).map { CGFloat(truncating: $0) } ?? 28
        )
    }
}

/**
 * 一个页面入栈时冻结的转场协议。
 *
 * requestedStyle 表示页面请求，baseEffectiveStyle 表示参数解析后的平台基础映射。
 * explicitlyRequested 是动画所有权开关：只要调用方显式传 transition/routeType，
 * 包括任何 fallback 都必须由 ShellNavigationAnimator 接管，不能返回 UIKit 默认动画。
 */
struct ShellTransitionSpec {
    let requestedStyle: ShellTransitionStyle
    let baseEffectiveStyle: ShellTransitionStyle
    let fallbackStyle: ShellTransitionStyle
    let durationMilliseconds: Int
    let reverseDurationMilliseconds: Int
    let readyTimeoutMilliseconds: Int
    let sharedElements: [ShellSharedElementSpec]
    let openContainer: ShellOpenContainerSpec?
    let popGesture: ShellPopGestureSpec
    let routeType: ShellRouteType?
    let routeConfig: ShellRouteConfig
    let routeOptions: ShellRouteOptions
    let explicitlyRequested: Bool
    let initialReason: String?

    static let `default` = ShellTransitionSpec(
        requestedStyle: .default,
        baseEffectiveStyle: .default,
        fallbackStyle: .fade,
        durationMilliseconds: 300,
        reverseDurationMilliseconds: 300,
        readyTimeoutMilliseconds: 350,
        sharedElements: [],
        openContainer: nil,
        popGesture: .default,
        routeType: nil,
        routeConfig: .default,
        routeOptions: .default,
        explicitlyRequested: false,
        initialReason: nil
    )

    /** 旧调用只传 animated=false 时使用；该路径不触发系统动画。 */
    static let withoutAnimation = ShellTransitionSpec(
        requestedStyle: .default,
        baseEffectiveStyle: .none,
        fallbackStyle: .none,
        durationMilliseconds: 0,
        reverseDurationMilliseconds: 0,
        readyTimeoutMilliseconds: 350,
        sharedElements: [],
        openContainer: nil,
        popGesture: .default,
        routeType: nil,
        routeConfig: .default,
        routeOptions: .default,
        explicitlyRequested: true,
        initialReason: nil
    )

    /** 兼容旧原生实现只读取单个 sharedElement 的代码。 */
    var sharedElement: ShellSharedElementSpec? { sharedElements.first }

    var needsTargetReadiness: Bool {
        baseEffectiveStyle == .sharedElement || baseEffectiveStyle == .openContainer
    }

    var usesCustomAnimator: Bool {
        baseEffectiveStyle != .none && (
            explicitlyRequested ||
            ![ShellTransitionStyle.default, .none].contains(baseEffectiveStyle)
        )
    }

    func durationMilliseconds(for direction: ShellTransitionDirection) -> Int {
        direction == .pop ? reverseDurationMilliseconds : durationMilliseconds
    }

    var dictionary: [String: Any] {
        var value: [String: Any] = [
            "requestedStyle": requestedStyle.rawValue,
            "baseEffectiveStyle": baseEffectiveStyle.rawValue,
            "fallbackStyle": fallbackStyle.rawValue,
            "durationMs": durationMilliseconds,
            "reverseDurationMs": reverseDurationMilliseconds,
            "readyTimeoutMs": readyTimeoutMilliseconds,
            "sharedElements": sharedElements.map(\.dictionary),
            "popGesture": popGesture.dictionary,
            "routeConfig": routeConfig.dictionary,
            "routeOptions": routeOptions.dictionary,
            "explicitlyRequested": explicitlyRequested,
        ]
        // 同时落旧字段，旧版本恢复时仍能读取首个共享元素。
        if let sharedElement { value["sharedElement"] = sharedElement.dictionary }
        if let openContainer { value["openContainer"] = openContainer.dictionary }
        if let routeType { value["routeType"] = routeType.rawValue }
        if let initialReason { value["initialReason"] = initialReason }
        return value
    }

    static func fromDictionary(_ value: [String: Any]) -> ShellTransitionSpec? {
        guard let requested = ShellTransitionStyle(
            rawValue: value["requestedStyle"] as? String ?? ""
        ),
        let effective = ShellTransitionStyle(
            rawValue: value["baseEffectiveStyle"] as? String ?? ""
        ),
        let fallback = ShellTransitionStyle(
            rawValue: value["fallbackStyle"] as? String ?? ""
        ),
        let duration = number(value["durationMs"])?.intValue,
        let timeout = number(value["readyTimeoutMs"])?.intValue else {
            return nil
        }

        let persistedShared = (value["sharedElements"] as? [[String: Any]])?
            .compactMap(ShellSharedElementSpec.fromDictionary)
        let legacyShared = (value["sharedElement"] as? [String: Any])
            .flatMap(ShellSharedElementSpec.fromDictionary)
        let sharedElements = persistedShared?.isEmpty == false
            ? Array(persistedShared!.prefix(8))
            : legacyShared.map { [$0] } ?? []
        let routeType = (value["routeType"] as? String).flatMap(ShellRouteType.init(rawValue:))

        return ShellTransitionSpec(
            requestedStyle: requested,
            baseEffectiveStyle: effective,
            fallbackStyle: fallback,
            durationMilliseconds: duration,
            reverseDurationMilliseconds:
                number(value["reverseDurationMs"])?.intValue ?? duration,
            readyTimeoutMilliseconds: timeout,
            sharedElements: sharedElements,
            openContainer: (value["openContainer"] as? [String: Any]).flatMap(
                ShellOpenContainerSpec.fromDictionary
            ),
            popGesture: (value["popGesture"] as? [String: Any]).map(
                ShellPopGestureSpec.fromDictionary
            ) ?? .default,
            routeType: routeType,
            routeConfig: (value["routeConfig"] as? [String: Any]).map(
                ShellRouteConfig.fromDictionary
            ) ?? .default,
            routeOptions: (value["routeOptions"] as? [String: Any]).map {
                ShellRouteOptions.fromDictionary($0, routeType: routeType)
            } ?? (routeType == .heroSheet ? .heroDefault : .default),
            explicitlyRequested: bool(value["explicitlyRequested"])
                ?? (routeType != nil || requested != .default),
            initialReason: value["initialReason"] as? String
        )
    }

    /** 从 open options 解析并执行统一范围校验。 */
    static func parse(options: [String: Any], animated: Bool) throws -> ShellTransitionSpec {
        let transition = try object(
            options["transition"],
            field: "transition",
            defaultValue: [:]
        )
        let routeType = try parseRouteType(options["routeType"])
        let transparent = bool(options["transparent"]) ?? false
        let explicitlyRequested = !animated ||
            options["transition"] != nil ||
            routeType != nil ||
            transparent

        let requestedStyle: ShellTransitionStyle
        if let styleValue = transition["style"] {
            guard let styleName = styleValue as? String,
                  let style = ShellTransitionStyle(rawValue: styleName) else {
                throw LynxRouteError.invalidArgument("transition.style 不受支持")
            }
            requestedStyle = style
        } else {
            requestedStyle = routeType?.diagnosticStyle ?? .default
        }

        let fallbackName = transition["fallbackStyle"] as? String ?? "fade"
        guard let fallback = ShellTransitionStyle(rawValue: fallbackName),
              [.fade, .slide, .none].contains(fallback) else {
            throw LynxRouteError.invalidArgument(
                "fallbackStyle 只支持 fade、slide、none"
            )
        }

        let defaultTransitionDuration = routeType == .bottomSheet
            ? ShellBottomSheetMotion.defaultDurationMilliseconds
            : 300
        let transitionDuration = try boundedInt(
            transition["durationMs"],
            field: "transition.durationMs",
            fallback: defaultTransitionDuration,
            range: 0 ... 5_000
        )
        let timeout = try boundedInt(
            transition["readyTimeoutMs"],
            field: "transition.readyTimeoutMs",
            fallback: 350,
            range: 80 ... 1_500
        )

        var routeConfig = try parseRouteConfig(options["routeConfig"])
        if transparent || routeType == .heroSheet {
            routeConfig = routeConfig.transparentized()
        }
        let routeOptions = try parseRouteOptions(
            options["routeOptions"],
            routeType: routeType
        )
        let sharedElements = try parseSharedElements(
            arrayValue: transition["sharedElements"],
            legacyValue: transition["sharedElement"]
        )
        let openContainer = try parseOpenContainer(transition["openContainer"])

        if requestedStyle == .sharedElement, sharedElements.isEmpty {
            throw LynxRouteError.invalidArgument(
                "sharedElement 转场必须提供 transition.sharedElements 或 sharedElement"
            )
        }
        if requestedStyle == .openContainer, openContainer == nil {
            throw LynxRouteError.invalidArgument(
                "openContainer 转场必须提供 transition.openContainer"
            )
        }

        var popGesture = try parsePopGesture(transition["popGesture"])
        let routeDefaultDirection: ShellPopGestureSpec.Direction? =
            routeType == .bottomSheet || routeType == .heroSheet ? .vertical : nil
        let direction = routeConfig.popGestureDirection
            ?? routeDefaultDirection
            ?? popGesture.direction
        let fullScreen = routeConfig.fullscreenDrag
            ?? (routeType == .bottomSheet || routeType == .heroSheet
                ? true
                : popGesture.fullScreen)
        popGesture = ShellPopGestureSpec(
            enabled: popGesture.enabled,
            direction: direction,
            fullScreen: fullScreen,
            edgeWidth: popGesture.edgeWidth
        )

        let openDuration = requestedStyle == .openContainer
            ? openContainer?.transitionDurationMilliseconds
            : nil
        let duration = routeConfig.transitionDurationMilliseconds
            ?? openDuration
            ?? transitionDuration
        let reverseDuration = routeConfig.reverseTransitionDurationMilliseconds
            ?? duration

        let nativeAnimationEnabled = animated && routeType != .heroSheet
        return ShellTransitionSpec(
            requestedStyle: requestedStyle,
            baseEffectiveStyle: nativeAnimationEnabled ? requestedStyle : .none,
            fallbackStyle: nativeAnimationEnabled ? fallback : .none,
            durationMilliseconds: duration,
            reverseDurationMilliseconds: reverseDuration,
            readyTimeoutMilliseconds: timeout,
            sharedElements: sharedElements,
            openContainer: openContainer,
            popGesture: popGesture,
            routeType: routeType,
            routeConfig: routeConfig,
            routeOptions: routeOptions,
            explicitlyRequested: explicitlyRequested,
            initialReason: nil
        )
    }

    private static func parseRouteType(_ rawValue: Any?) throws -> ShellRouteType? {
        guard let rawValue, !(rawValue is NSNull) else { return nil }
        guard let value = rawValue as? String,
              let routeType = ShellRouteType(rawValue: value) else {
            throw LynxRouteError.invalidArgument("routeType 不受支持: \(rawValue)")
        }
        return routeType
    }

    private static func parseRouteConfig(_ rawValue: Any?) throws -> ShellRouteConfig {
        let value = try object(rawValue, field: "routeConfig", defaultValue: [:])
        let duration = try optionalBoundedInt(
            value["transitionDuration"],
            field: "routeConfig.transitionDuration",
            range: 0 ... 5_000
        )
        let reverseDuration = try optionalBoundedInt(
            value["reverseTransitionDuration"],
            field: "routeConfig.reverseTransitionDuration",
            range: 0 ... 5_000
        )
        let direction: ShellPopGestureSpec.Direction?
        if let rawDirection = value["popGestureDirection"] {
            guard let name = rawDirection as? String,
                  let parsed = ShellPopGestureSpec.Direction(rawValue: name) else {
                throw LynxRouteError.invalidArgument(
                    "routeConfig.popGestureDirection 只支持 horizontal、vertical、multi"
                )
            }
            direction = parsed
        } else {
            direction = nil
        }
        let barrierLabel: String?
        if let rawLabel = value["barrierLabel"] {
            guard let label = rawLabel as? String, label.count <= 128 else {
                throw LynxRouteError.invalidArgument(
                    "routeConfig.barrierLabel 不能超过 128 个字符"
                )
            }
            barrierLabel = label
        } else {
            barrierLabel = nil
        }

        return ShellRouteConfig(
            transitionDurationMilliseconds: duration,
            reverseTransitionDurationMilliseconds: reverseDuration,
            opaque: bool(value["opaque"]),
            maintainState: bool(value["maintainState"]) ?? true,
            barrierColor: try color(
                value["barrierColor"],
                field: "routeConfig.barrierColor"
            ),
            barrierDismissible: bool(value["barrierDismissible"]),
            barrierLabel: barrierLabel,
            canTransitionTo: bool(value["canTransitionTo"]) ?? true,
            canTransitionFrom: bool(value["canTransitionFrom"]) ?? true,
            allowEnterRouteSnapshotting:
                bool(value["allowEnterRouteSnapshotting"]) ?? true,
            allowExitRouteSnapshotting:
                bool(value["allowExitRouteSnapshotting"]) ?? true,
            fullscreenDrag: bool(value["fullscreenDrag"]),
            popGestureDirection: direction
        )
    }

    private static func parseRouteOptions(
        _ rawValue: Any?,
        routeType: ShellRouteType?
    ) throws -> ShellRouteOptions {
        let value = try object(rawValue, field: "routeOptions", defaultValue: [:])
        let explicitHeight: CGFloat?
        if value["height"] == nil {
            explicitHeight = nil
        } else {
            explicitHeight = try boundedCGFloat(
                value["height"],
                field: "routeOptions.height",
                fallback: ShellBottomSheetMotion.defaultHeightVH,
                range: 1 ... 100
            )
        }
        let detents: [CGFloat]
        if let rawDetents = value["detents"] {
            guard let values = rawDetents as? [Any],
                  values.count >= 1,
                  values.count <= ShellHeroSheetMotion.maximumDetents else {
                throw LynxRouteError.invalidArgument(
                    "routeOptions.detents 数量必须在 1...\(ShellHeroSheetMotion.maximumDetents) 之间"
                )
            }
            detents = try values.enumerated().map { index, rawValue in
                try boundedCGFloat(
                    rawValue,
                    field: "routeOptions.detents[\(index)]",
                    fallback: 0,
                    range: 1 ... 100
                )
            }
            guard zip(detents, detents.dropFirst()).allSatisfy({ pair in
                pair.0 < pair.1
            }) else {
                throw LynxRouteError.invalidArgument(
                    "routeOptions.detents 必须严格递增"
                )
            }
        } else if let explicitHeight {
            detents = [explicitHeight]
        } else if routeType == .heroSheet {
            detents = ShellHeroSheetMotion.defaultDetentsVH
        } else {
            detents = [ShellBottomSheetMotion.defaultHeightVH]
        }
        if routeType == .heroSheet, detents.count < 2 {
            throw LynxRouteError.invalidArgument("heroSheet 至少需要两个 detent")
        }
        if routeType == .heroSheet,
           abs((detents.last ?? 0) - 100) >= 0.0001 {
            throw LynxRouteError.invalidArgument(
                "heroSheet 的最后一个 detent 必须是 100vh 全屏"
            )
        }
        let usesHeroDefaults = routeType == .heroSheet &&
            value["detents"] == nil && explicitHeight == nil
        let requestedInitial = try boundedCGFloat(
            value["initialDetent"],
            field: "routeOptions.initialDetent",
            fallback: usesHeroDefaults
                ? ShellHeroSheetMotion.defaultInitialDetentVH
                : (explicitHeight ?? detents.last ?? ShellBottomSheetMotion.defaultHeightVH),
            range: 1 ... 100
        )
        guard let initialIndex = detents.firstIndex(where: {
            abs($0 - requestedInitial) < 0.0001
        }) else {
            throw LynxRouteError.invalidArgument(
                "routeOptions.initialDetent 必须是 detents 中的一个值"
            )
        }
        return ShellRouteOptions(
            round: bool(value["round"]) ?? true,
            heightVH: requestedInitial,
            detentsVH: detents,
            initialDetentVH: requestedInitial,
            initialDetentIndex: initialIndex
        )
    }

    private static func parseSharedElements(
        arrayValue: Any?,
        legacyValue: Any?
    ) throws -> [ShellSharedElementSpec] {
        let rawItems: [Any]
        if let arrayValue {
            guard let array = arrayValue as? [Any] else {
                throw LynxRouteError.invalidArgument("sharedElements 必须是 JSON Array")
            }
            guard array.count <= 8 else {
                throw LynxRouteError.invalidArgument("sharedElements 最多支持 8 个元素")
            }
            rawItems = array
        } else if let legacyValue {
            rawItems = [legacyValue]
        } else {
            return []
        }

        var keys = Set<String>()
        return try rawItems.enumerated().map { index, rawValue in
            guard let value = rawValue as? [String: Any] else {
                throw LynxRouteError.invalidArgument(
                    "sharedElements[\(index)] 必须是 JSON Object"
                )
            }
            let descriptor = try parseSharedElement(value, prefix: "sharedElements[\(index)]")
            guard keys.insert(descriptor.key).inserted else {
                throw LynxRouteError.invalidArgument(
                    "sharedElements.key 必须唯一: \(descriptor.key)"
                )
            }
            return descriptor
        }
    }

    private static func parseSharedElement(
        _ value: [String: Any],
        prefix: String
    ) throws -> ShellSharedElementSpec {
        let key = try selectorLike(value["key"], field: "\(prefix).key", stripHash: false)
        let source = try selectorLike(
            value["sourceSelector"],
            field: "\(prefix).sourceSelector",
            stripHash: true
        )
        let target = try selectorLike(
            value["targetSelector"],
            field: "\(prefix).targetSelector",
            stripHash: true
        )
        let pushName = value["shuttleOnPush"] as? String ?? "to"
        let popName = value["shuttleOnPop"] as? String ?? "to"
        guard let pushShuttle = ShellSharedElementShuttle(rawValue: pushName),
              let popShuttle = ShellSharedElementShuttle(rawValue: popName) else {
            throw LynxRouteError.invalidArgument(
                "\(prefix).shuttleOnPush/Pop 只支持 from、to"
            )
        }
        let tweenName = value["rectTweenType"] as? String ?? "materialRectArc"
        guard let tween = ShellRectTweenType.parse(tweenName) else {
            throw LynxRouteError.invalidArgument(
                "\(prefix).rectTweenType 不受支持"
            )
        }
        return ShellSharedElementSpec(
            key: key,
            sourceSelector: source,
            targetSelector: target,
            transitionOnGesture: bool(value["transitionOnGesture"]) ?? false,
            shuttleOnPush: pushShuttle,
            shuttleOnPop: popShuttle,
            rectTweenType: tween,
            sourceStyle: try parseRectStyle(value["sourceStyle"], field: "\(prefix).sourceStyle"),
            targetStyle: try parseRectStyle(value["targetStyle"], field: "\(prefix).targetStyle")
        )
    }

    private static func parseOpenContainer(_ rawValue: Any?) throws -> ShellOpenContainerSpec? {
        guard let rawValue else { return nil }
        guard let value = rawValue as? [String: Any] else {
            throw LynxRouteError.invalidArgument("openContainer 必须是 JSON Object")
        }
        // transitionType 为新字段，contentTransition 为旧壳兼容字段。
        let transitionName = value["transitionType"] as? String
            ?? value["contentTransition"] as? String
            ?? "fade"
        guard let transitionType = ShellOpenContainerSpec.TransitionType(
            rawValue: transitionName
        ) else {
            throw LynxRouteError.invalidArgument(
                "openContainer.transitionType 只支持 fade、fadeThrough"
            )
        }
        return ShellOpenContainerSpec(
            sourceSelector: try selectorLike(
                value["sourceSelector"],
                field: "openContainer.sourceSelector",
                stripHash: true
            ),
            closedColor: try color(value["closedColor"], field: "closedColor") ?? "white",
            middleColor: try optionalColorAllowingEmpty(
                value["middleColor"],
                field: "middleColor"
            ),
            openColor: try color(value["openColor"], field: "openColor") ?? "white",
            closedCornerRadius: try boundedCGFloat(
                value["closedCornerRadius"],
                field: "closedCornerRadius",
                fallback: 0,
                range: 0 ... 256
            ),
            openCornerRadius: try boundedCGFloat(
                value["openCornerRadius"],
                field: "openCornerRadius",
                fallback: 0,
                range: 0 ... 256
            ),
            closedElevation: try boundedCGFloat(
                value["closedElevation"],
                field: "closedElevation",
                fallback: 0,
                range: 0 ... 64
            ),
            openElevation: try boundedCGFloat(
                value["openElevation"],
                field: "openElevation",
                fallback: 0,
                range: 0 ... 64
            ),
            transitionType: transitionType,
            transitionDurationMilliseconds: try boundedInt(
                value["transitionDuration"],
                field: "openContainer.transitionDuration",
                fallback: 300,
                range: 0 ... 5_000
            )
        )
    }

    private static func parsePopGesture(_ rawValue: Any?) throws -> ShellPopGestureSpec {
        let value = try object(rawValue, field: "popGesture", defaultValue: [:])
        let directionName = value["direction"] as? String ?? "horizontal"
        guard let direction = ShellPopGestureSpec.Direction(rawValue: directionName) else {
            throw LynxRouteError.invalidArgument(
                "popGesture.direction 只支持 horizontal、vertical、multi"
            )
        }
        let edgeWidth = try boundedCGFloat(
            value["edgeWidth"],
            field: "popGesture.edgeWidth",
            fallback: 28,
            range: 16 ... 72
        )
        return ShellPopGestureSpec(
            enabled: bool(value["enabled"]) ?? true,
            direction: direction,
            fullScreen: bool(value["fullScreen"]) ?? false,
            edgeWidth: edgeWidth
        )
    }

    private static func parseRectStyle(
        _ rawValue: Any?,
        field: String
    ) throws -> ShellRectStyle? {
        guard let rawValue else { return nil }
        guard let value = rawValue as? [String: Any] else {
            throw LynxRouteError.invalidArgument("\(field) 必须是 JSON Object")
        }
        return ShellRectStyle(
            backgroundColor: try color(value["backgroundColor"], field: "\(field).backgroundColor"),
            cornerRadius: try optionalBoundedCGFloat(
                value["cornerRadius"],
                field: "\(field).cornerRadius",
                range: 0 ... 256
            ),
            elevation: try optionalBoundedCGFloat(
                value["elevation"],
                field: "\(field).elevation",
                range: 0 ... 64
            )
        )
    }

    private static func object(
        _ rawValue: Any?,
        field: String,
        defaultValue: [String: Any]
    ) throws -> [String: Any] {
        guard let rawValue, !(rawValue is NSNull) else { return defaultValue }
        guard let value = rawValue as? [String: Any] else {
            throw LynxRouteError.invalidArgument("\(field) 必须是 JSON Object")
        }
        return value
    }

    private static func selectorLike(
        _ value: Any?,
        field: String,
        stripHash: Bool
    ) throws -> String {
        guard var value = value as? String else {
            throw LynxRouteError.invalidArgument("\(field) 不能为空")
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripHash, value.hasPrefix("#") { value.removeFirst() }
        guard !value.isEmpty, value.count <= 128 else {
            throw LynxRouteError.invalidArgument("\(field) 长度必须在 1...128 之间")
        }
        return value
    }

    private static func color(_ rawValue: Any?, field: String) throws -> String? {
        guard let rawValue, !(rawValue is NSNull) else { return nil }
        guard let value = rawValue as? String,
              isSupportedColor(value) else {
            throw LynxRouteError.invalidArgument(
                "\(field) 必须为受支持命名色、#RRGGBB/#RRGGBBAA、rgb() 或 rgba()"
            )
        }
        return value
    }

    /** Open Container 官方 middleColor 默认空；空字符串等价于未声明。 */
    private static func optionalColorAllowingEmpty(
        _ rawValue: Any?,
        field: String
    ) throws -> String? {
        guard let rawValue, !(rawValue is NSNull) else { return nil }
        guard let value = rawValue as? String else {
            throw LynxRouteError.invalidArgument("\(field) 必须是颜色字符串")
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return try color(normalized, field: field)
    }

    private static func isSupportedColor(_ rawValue: String) -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let namedColors = [
            "black", "darkgray", "gray", "lightgray", "white",
            "red", "green", "blue", "yellow", "cyan", "magenta", "transparent",
        ]
        if namedColors.contains(value) { return true }
        if value.range(
            of: "^#[0-9a-f]{6}([0-9a-f]{2})?$",
            options: .regularExpression
        ) != nil {
            return true
        }
        let isRGBA = value.hasPrefix("rgba(") && value.hasSuffix(")")
        let isRGB = value.hasPrefix("rgb(") && value.hasSuffix(")")
        guard isRGBA || isRGB else { return false }
        let prefixLength = isRGBA ? 5 : 4
        let start = value.index(value.startIndex, offsetBy: prefixLength)
        let end = value.index(before: value.endIndex)
        let parts = value[start..<end]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == (isRGBA ? 4 : 3) else { return false }
        guard parts.prefix(3).allSatisfy(isSupportedColorChannel) else {
            return false
        }
        guard isRGBA else { return true }
        return isSupportedAlpha(parts[3])
    }

    private static func isSupportedColorChannel(_ rawValue: String) -> Bool {
        if rawValue.hasSuffix("%") {
            guard let percent = Double(rawValue.dropLast()) else { return false }
            return (0 ... 100).contains(percent)
        }
        guard let channel = Double(rawValue) else { return false }
        return (0 ... 255).contains(channel)
    }

    private static func isSupportedAlpha(_ rawValue: String) -> Bool {
        if rawValue.hasSuffix("%") {
            guard let percent = Double(rawValue.dropLast()) else { return false }
            return (0 ... 100).contains(percent)
        }
        guard let alpha = Double(rawValue) else { return false }
        return (0 ... 1).contains(alpha)
    }

    private static func boundedInt(
        _ rawValue: Any?,
        field: String,
        fallback: Int,
        range: ClosedRange<Int>
    ) throws -> Int {
        guard let rawValue else { return fallback }
        guard let value = number(rawValue)?.intValue, range.contains(value) else {
            throw LynxRouteError.invalidArgument(
                "\(field) 必须在 \(range.lowerBound)...\(range.upperBound) 之间"
            )
        }
        return value
    }

    private static func optionalBoundedInt(
        _ rawValue: Any?,
        field: String,
        range: ClosedRange<Int>
    ) throws -> Int? {
        guard let rawValue else { return nil }
        return try boundedInt(
            rawValue,
            field: field,
            fallback: range.lowerBound,
            range: range
        )
    }

    private static func boundedCGFloat(
        _ rawValue: Any?,
        field: String,
        fallback: CGFloat,
        range: ClosedRange<CGFloat>
    ) throws -> CGFloat {
        guard let rawValue else { return fallback }
        guard let value = number(rawValue).map({ CGFloat(truncating: $0) }),
              range.contains(value) else {
            throw LynxRouteError.invalidArgument(
                "\(field) 必须在 \(range.lowerBound)...\(range.upperBound) 之间"
            )
        }
        return value
    }

    private static func optionalBoundedCGFloat(
        _ rawValue: Any?,
        field: String,
        range: ClosedRange<CGFloat>
    ) throws -> CGFloat? {
        guard let rawValue else { return nil }
        return try boundedCGFloat(rawValue, field: field, fallback: 0, range: range)
    }
}

/** 注入目标 Lynx 页面 globalProps.nativeTransition 的只读上下文。 */
struct ShellNativeTransitionMetadata {
    let transactionID: String
    let requestedTransition: ShellTransitionStyle
    let effectiveTransition: ShellTransitionStyle
    let direction: ShellTransitionDirection
    let reason: String?

    var dictionary: [String: Any] {
        var value: [String: Any] = [
            "transactionID": transactionID,
            "requestedTransition": requestedTransition.rawValue,
            "effectiveTransition": effectiveTransition.rawValue,
            "direction": direction.rawValue,
        ]
        if let reason { value["reason"] = reason }
        return value
    }
}

/** NativeModules.getTransitionState 与 onRouteDone/onTransitionSettled 共用的稳定状态。 */
struct ShellTransitionState {
    enum Status: String {
        case idle
        case accepted
        case waitingTarget
        case running
        case settling
        case completed
        case cancelled
        case degraded
        case failed
    }

    let transactionID: String
    let status: Status
    let requestedTransition: ShellTransitionStyle
    let effectiveTransition: ShellTransitionStyle
    let direction: ShellTransitionDirection
    let progress: CGFloat
    let reason: String?
    let routeKey: String?
    let updatedAtMilliseconds: Int64

    static let idle = ShellTransitionState(
        transactionID: "",
        status: .idle,
        requestedTransition: .default,
        effectiveTransition: .default,
        direction: .push,
        progress: 0,
        reason: nil,
        routeKey: nil,
        updatedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
    )

    var dictionary: [String: Any] {
        var value: [String: Any] = [
            "transactionID": transactionID,
            "status": status.rawValue,
            "requestedTransition": requestedTransition.rawValue,
            "effectiveTransition": effectiveTransition.rawValue,
            "direction": direction.rawValue,
            "progress": Double(progress),
            "updatedAt": updatedAtMilliseconds,
        ]
        if let reason { value["reason"] = reason }
        if let routeKey { value["routeKey"] = routeKey }
        return value
    }
}

private func number(_ value: Any?) -> NSNumber? {
    if let value = value as? NSNumber { return value }
    if let value = value as? String, let double = Double(value) {
        return NSNumber(value: double)
    }
    return nil
}

private func bool(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = value as? String {
        if ["1", "true", "yes"].contains(value.lowercased()) { return true }
        if ["0", "false", "no"].contains(value.lowercased()) { return false }
    }
    return nil
}
