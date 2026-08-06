import Foundation

/** 一个 Lynx 原生页面的完整描述。 */
struct LynxPageRequest {
    enum Orientation: String {
        case system
        case portrait
        case landscape
    }

    let bundleURL: String
    /** OTA 逻辑应用身份；与 bundleName 同时存在时才进入 Router 内置 OTA 引擎。 */
    let lynxAppId: String?
    /** Manifest 中的精确相对 Bundle 名称，不是本机沙盒绝对路径。 */
    let bundleName: String?
    /** 页面栈稳定标识；未显式传入时使用 Bundle URL。 */
    let routeKey: String
    let title: String
    let initialData: [String: Any]
    let globalProps: [String: Any]
    let fullscreen: Bool
    let showNavigationBar: Bool
    let hideStatusBar: Bool
    /** 是否允许系统侧滑返回；导航栏返回和 NativeModules 关闭能力始终保留。 */
    let backGestureEnabled: Bool
    let allowHTTPInDebug: Bool
    let orientation: Orientation
    let backgroundColor: String
    let widthInPhysicalPixels: CGFloat?
    let heightInPhysicalPixels: CGFloat?
    /** 页面入栈时冻结的原生转场配置；未传时完整保留 UIKit 默认行为。 */
    let transitionSpec: ShellTransitionSpec
    /**
     * 当前导航事务注入给目标 Lynx 页的只读上下文。
     *
     * 它只在本次进程内有效，不进入 Scene 恢复快照，避免恢复一笔已经结束的动画。
     */
    let nativeTransition: ShellNativeTransitionMetadata?

    /**
     * 显式初始化器把页面与导航展示参数集中在一个稳定签名中。
     *
     * backGestureEnabled 提供默认值，既保持旧调用兼容，也允许路由 options 明确关闭
     * 系统侧滑返回。
     */
    init(
        bundleURL: String,
        lynxAppId: String? = nil,
        bundleName: String? = nil,
        routeKey: String,
        title: String,
        initialData: [String: Any],
        globalProps: [String: Any],
        fullscreen: Bool,
        showNavigationBar: Bool,
        hideStatusBar: Bool,
        backGestureEnabled: Bool = true,
        allowHTTPInDebug: Bool,
        orientation: Orientation,
        backgroundColor: String,
        widthInPhysicalPixels: CGFloat?,
        heightInPhysicalPixels: CGFloat?,
        transitionSpec: ShellTransitionSpec = .default,
        nativeTransition: ShellNativeTransitionMetadata? = nil
    ) {
        self.bundleURL = bundleURL
        self.lynxAppId = lynxAppId
        self.bundleName = bundleName
        self.routeKey = routeKey
        self.title = title
        self.initialData = initialData
        self.globalProps = globalProps
        self.fullscreen = fullscreen
        self.showNavigationBar = showNavigationBar
        self.hideStatusBar = hideStatusBar
        self.backGestureEnabled = backGestureEnabled
        self.allowHTTPInDebug = allowHTTPInDebug
        self.orientation = orientation
        self.backgroundColor = backgroundColor
        self.widthInPhysicalPixels = widthInPhysicalPixels
        self.heightInPhysicalPixels = heightInPhysicalPixels
        self.transitionSpec = transitionSpec
        self.nativeTransition = nativeTransition
    }

    /** 在创建 LynxView 前校验协议、尺寸和颜色。 */
    func validated() throws -> LynxPageRequest {
        guard !bundleURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LynxRouteError.invalidArgument("Bundle URL 不能为空")
        }
        guard Self.isSupported(bundleURL) else {
            throw LynxRouteError.unsupportedURL(bundleURL)
        }
        let hasAppId = lynxAppId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasBundleName = bundleName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard hasAppId == hasBundleName else {
            throw LynxRouteError.invalidArgument("OTA 请求必须同时提供 lynxAppId 和 bundleName")
        }
        if hasAppId, let lynxAppId, let bundleName {
            guard lynxAppId.count <= 256 else {
                throw LynxRouteError.invalidArgument("lynxAppId 不能超过 256 个字符")
            }
            let segments = bundleName.split(separator: "/", omittingEmptySubsequences: false)
            guard bundleName.lowercased().hasSuffix(".lynx.bundle"),
                  !(bundleName as NSString).isAbsolutePath,
                  !bundleName.contains("\\"),
                  !bundleName.contains("\0"),
                  !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw LynxRouteError.invalidArgument("bundleName 必须是安全的相对 .lynx.bundle 路径")
            }
        }
        guard resolvedRouteKey.count <= 256 else {
            throw LynxRouteError.invalidArgument("routeKey 不能超过 256 个字符")
        }

        if RemoteBundlePolicy.isRemote(bundleURL) {
            guard let url = URL(string: bundleURL), url.host?.isEmpty == false else {
                throw LynxRouteError.invalidArgument("远程 Bundle URL 缺少合法域名")
            }
            if url.scheme?.lowercased() == "http" {
                #if DEBUG
                guard allowHTTPInDebug else {
                    throw LynxRouteError.invalidArgument("HTTP 仅允许在 Debug 显式开启")
                }
                #else
                throw LynxRouteError.invalidArgument("Release 禁止明文 HTTP Bundle")
                #endif
            }
        }

        guard backgroundColor.range(
            of: "^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$",
            options: .regularExpression
        ) != nil else {
            throw LynxRouteError.invalidArgument("backgroundColor 必须为 #RRGGBB 或 #RRGGBBAA")
        }
        if let widthInPhysicalPixels, widthInPhysicalPixels <= 0 {
            throw LynxRouteError.invalidArgument("width 必须大于 0")
        }
        if let heightInPhysicalPixels, heightInPhysicalPixels <= 0 {
            throw LynxRouteError.invalidArgument("height 必须大于 0")
        }
        return self
    }

    var resolvedRouteKey: String {
        let normalized = routeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty
            ? (bundleName ?? bundleURL).trimmingCharacters(in: .whitespacesAndNewlines)
            : normalized
    }

    /** 只有显式逻辑身份的请求才进入 OTA；HTTPS URL 永远不会据此反查 appId。 */
    var isOtaRequest: Bool {
        lynxAppId?.isEmpty == false && bundleName?.isEmpty == false
    }

    /**
     * 生成仅包含 JSON 可序列化字段的导航恢复快照。
     *
     * Runtime 对象、UIViewController、Provider 和回调都不会写入持久层；恢复时重新创建
     * 容器并重新加载 Bundle。
     */
    var navigationSnapshot: [String: Any] {
        var value: [String: Any] = [
            "bundleURL": bundleURL,
            "routeKey": resolvedRouteKey,
            "title": title,
            "initialData": initialData,
            "globalProps": globalProps,
            "fullscreen": fullscreen,
            "showNavigationBar": showNavigationBar,
            "hideStatusBar": hideStatusBar,
            "backGestureEnabled": backGestureEnabled,
            "allowHTTPInDebug": allowHTTPInDebug,
            "orientation": orientation.rawValue,
            "backgroundColor": backgroundColor,
            "transitionSpec": transitionSpec.dictionary,
        ]
        if let lynxAppId { value["lynxAppId"] = lynxAppId }
        if let bundleName { value["bundleName"] = bundleName }
        if let widthInPhysicalPixels {
            value["widthInPhysicalPixels"] = Double(widthInPhysicalPixels)
        }
        if let heightInPhysicalPixels {
            value["heightInPhysicalPixels"] = Double(heightInPhysicalPixels)
        }
        return value
    }

    /** 从持久快照恢复并重新执行完整安全校验；任意字段非法都返回 nil。 */
    static func fromNavigationSnapshot(_ value: [String: Any]) -> LynxPageRequest? {
        guard let bundleURL = value["bundleURL"] as? String,
              let routeKey = value["routeKey"] as? String,
              let title = value["title"] as? String,
              let initialData = value["initialData"] as? [String: Any],
              let globalProps = value["globalProps"] as? [String: Any],
              let fullscreen = value["fullscreen"] as? Bool,
              let showNavigationBar = value["showNavigationBar"] as? Bool,
              let hideStatusBar = value["hideStatusBar"] as? Bool,
              let allowHTTPInDebug = value["allowHTTPInDebug"] as? Bool,
              let orientationValue = value["orientation"] as? String,
              let orientation = Orientation(rawValue: orientationValue),
              let backgroundColor = value["backgroundColor"] as? String,
              JSONSerialization.isValidJSONObject(initialData),
              JSONSerialization.isValidJSONObject(globalProps) else {
            return nil
        }
        let backGestureEnabled = value["backGestureEnabled"] as? Bool ?? true
        let width = (value["widthInPhysicalPixels"] as? NSNumber).map {
            CGFloat(truncating: $0)
        }
        let height = (value["heightInPhysicalPixels"] as? NSNumber).map {
            CGFloat(truncating: $0)
        }
        let transitionSpec = (value["transitionSpec"] as? [String: Any])
            .flatMap(ShellTransitionSpec.fromDictionary) ?? .default
        return try? LynxPageRequest(
            bundleURL: bundleURL,
            lynxAppId: value["lynxAppId"] as? String,
            bundleName: value["bundleName"] as? String,
            routeKey: routeKey,
            title: title,
            initialData: initialData,
            globalProps: globalProps,
            fullscreen: fullscreen,
            showNavigationBar: showNavigationBar,
            hideStatusBar: hideStatusBar,
            backGestureEnabled: backGestureEnabled,
            allowHTTPInDebug: allowHTTPInDebug,
            orientation: orientation,
            backgroundColor: backgroundColor,
            widthInPhysicalPixels: width,
            heightInPhysicalPixels: height,
            transitionSpec: transitionSpec
        ).validated()
    }

    /** 复制页面请求并冻结一次 open 解析得到的转场配置。 */
    func withTransitionSpec(_ value: ShellTransitionSpec) -> LynxPageRequest {
        copying(transitionSpec: value, nativeTransition: nativeTransition)
    }

    /** 复制页面请求并注入本次原生转场上下文。 */
    func withNativeTransition(_ value: ShellNativeTransitionMetadata?) -> LynxPageRequest {
        copying(transitionSpec: transitionSpec, nativeTransition: value)
    }

    private func copying(
        transitionSpec: ShellTransitionSpec,
        nativeTransition: ShellNativeTransitionMetadata?
    ) -> LynxPageRequest {
        LynxPageRequest(
            bundleURL: bundleURL,
            lynxAppId: lynxAppId,
            bundleName: bundleName,
            routeKey: routeKey,
            title: title,
            initialData: initialData,
            globalProps: globalProps,
            fullscreen: fullscreen,
            showNavigationBar: showNavigationBar,
            hideStatusBar: hideStatusBar,
            backGestureEnabled: backGestureEnabled,
            allowHTTPInDebug: allowHTTPInDebug,
            orientation: orientation,
            backgroundColor: backgroundColor,
            widthInPhysicalPixels: widthInPhysicalPixels,
            heightInPhysicalPixels: heightInPhysicalPixels,
            transitionSpec: transitionSpec,
            nativeTransition: nativeTransition
        )
    }

    private static func isSupported(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.hasPrefix("assets://") ||
            lower.hasPrefix("https://") ||
            lower.hasPrefix("http://") ||
            lower.hasPrefix("file://lynx?local://") ||
            (!lower.contains("://") && lower.hasSuffix(".lynx.bundle"))
    }
}

/** 远程 Bundle 仅按 URL 协议识别；Host 不做白名单限制。 */
enum RemoteBundlePolicy {
    static func isRemote(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://")
    }

}

enum LynxRouteError: LocalizedError {
    case invalidArgument(String)
    case unsupportedURL(String)
    case missingBundle
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case let .invalidArgument(message): return message
        case let .unsupportedURL(url): return "不支持的 Bundle URL: \(url)"
        case .missingBundle: return "路由缺少 url 或 bundle 参数"
        case let .invalidJSON(field): return "\(field) 必须是合法 JSON Object"
        }
    }
}
