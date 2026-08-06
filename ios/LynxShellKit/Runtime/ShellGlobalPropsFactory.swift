import UIKit

/** 构造跨端保留字段；系统字段最后写入，避免被页面参数伪造。 */
enum ShellGlobalPropsFactory {
    static func make(
        for view: UIView,
        request: LynxPageRequest,
        pageId: String? = nil,
        sessionId: String? = nil
    ) -> [String: Any] {
        var props = request.globalProps
        let screen = UIScreen.main
        let info = Bundle.main.infoDictionary ?? [:]
        let insets = view.safeAreaInsets

        props["platform"] = "ios"
        // Sparkling Playground 的旧字段名。保留当前壳字段，同时提供兼容别名。
        props["os"] = "ios"
        props["screenWidth"] = screen.bounds.width
        props["screenHeight"] = screen.bounds.height
        props["density"] = screen.scale
        props["safeAreaTop"] = insets.top
        props["safeAreaBottom"] = insets.bottom
        props["safeAreaLeft"] = insets.left
        props["safeAreaRight"] = insets.right
        props["topHeight"] = insets.top
        props["bottomHeight"] = insets.bottom
        props["statusBarHeight"] = insets.top
        props["navigationBarHeight"] = insets.bottom
        props["isNotchScreen"] = insets.top > 20
        props["theme"] = view.traitCollection.userInterfaceStyle == .dark ? "Dark" : "Light"
        props["frontendTheme"] = "system"
        props["systemVersion"] = UIDevice.current.systemVersion
        props["locale"] = Locale.current.identifier
        props["appVersion"] = info["CFBundleShortVersionString"] as? String ?? ""
        props["buildNumber"] = info["CFBundleVersion"] as? String ?? ""
        // 页面应读取原生容器最终采用的 chrome 状态，避免原始 query 与 options 合并后
        // 留下过期值。其他业务参数保持不变，宿主保留字段在这里统一覆盖。
        var queryItems = props["queryItems"] as? [String: Any] ?? [:]
        queryItems["fullscreen"] = request.fullscreen ? "1" : "0"
        queryItems["hide_nav_bar"] = request.showNavigationBar ? "0" : "1"
        queryItems["hide_status_bar"] = request.hideStatusBar ? "1" : "0"
        queryItems["trans_status_bar"] =
            request.fullscreen && !request.hideStatusBar ? "1" : "0"
        props["queryItems"] = queryItems
        // v1 跨端契约：containerID 兼容旧 Shell 字段，但身份必须按“页面实例”唯一，
        // 不能再使用 Bundle hash，否则同一个 Bundle 多次 push 会互相覆盖消息目标。
        let resolvedPageId = pageId?.isEmpty == false ? pageId! : request.resolvedRouteKey
        let resolvedSessionId = sessionId?.isEmpty == false ? sessionId! : ""
        props["containerID"] = resolvedPageId
        props["__lynxRouterContainerId"] = resolvedPageId
        props["__lynxRouterPageId"] = resolvedPageId
        props["__lynxRouterPageKey"] = request.resolvedRouteKey
        props["__lynxRouterSessionId"] = resolvedSessionId
        props["__lynxRouterNavigationModel"] = "native_page_stack"
        props["__lynxRouterPlatformContainer"] = "uikit_view_controller"
        props["__lynxRouterParams"] = queryItems
        if let nativeTransition = request.nativeTransition {
            // 必须在 loadTemplate 之前注入，目标页首屏即可读取 transactionID 并按需
            // 调用 NativeModules.LynxShellModule.markTransitionReady。
            props["nativeTransition"] = nativeTransition.dictionary
        } else {
            props.removeValue(forKey: "nativeTransition")
        }
        return props
    }
}
