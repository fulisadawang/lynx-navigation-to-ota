import UIKit

/** 构造跨端保留字段；系统字段最后写入，避免被页面参数伪造。 */
enum ShellGlobalPropsFactory {
    static func make(
        for view: UIView,
        request: LynxPageRequest,
        pageId: String? = nil,
        sessionId: String? = nil,
        bundleMetadata: [String: Any]? = nil,
        localeState: LynxLocaleState? = nil,
        layoutSnapshot: ShellLayoutSnapshot? = nil
    ) -> [String: Any] {
        var props = request.globalProps
        let info = Bundle.main.infoDictionary ?? [:]
        let resolvedLocaleState = localeState ?? ShellLocaleStore.current()
        let resolvedLayoutSnapshot = layoutSnapshot ?? ShellLayoutSnapshot(
            revision: 0,
            timestampMillis: Int64(Date().timeIntervalSince1970 * 1000),
            measurement: ShellLayoutSnapshot.measure(for: view)
        )

        props["platform"] = "ios"
        // Sparkling Playground 的旧字段名。保留当前壳字段，同时提供兼容别名。
        props["os"] = "ios"
        props["theme"] = view.traitCollection.userInterfaceStyle == .dark ? "Dark" : "Light"
        props["frontendTheme"] = "system"
        props["systemVersion"] = UIDevice.current.systemVersion
        props["appVersion"] = info["CFBundleShortVersionString"] as? String ?? ""
        props["buildNumber"] = info["CFBundleVersion"] as? String ?? ""
        applyLayout(resolvedLayoutSnapshot, to: &props)
        applyLocale(resolvedLocaleState, to: &props)
        // 页面应读取原生容器最终采用的 chrome 状态，避免原始 query 与 options 合并后
        // 留下过期值。其他业务参数保持不变，宿主保留字段在这里统一覆盖。
        var queryItems: [String: Any] = [:]
        if let values = props["queryItems"] as? [String: Any] {
            queryItems = values
        } else if let values = props["queryItems"] as? [String: String] {
            // Native Tab 描述通常使用 [String: String]；显式桥接后再合并宿主字段，避免
            // Swift 泛型字典不协变导致 native_tab_id 被静默丢弃。
            queryItems = values.mapValues { $0 as Any }
        } else if let values = props["queryItems"] as? NSDictionary {
            values.forEach { key, value in
                if let key = key as? String {
                    queryItems[key] = value
                }
            }
        }
        queryItems["fullscreen"] = request.fullscreen ? "1" : "0"
        queryItems["hide_nav_bar"] = request.showNavigationBar ? "0" : "1"
        queryItems["hide_status_bar"] = request.hideStatusBar ? "1" : "0"
        queryItems["trans_status_bar"] =
            request.fullscreen && !request.hideStatusBar ? "1" : "0"
        queryItems["locale"] = resolvedLocaleState.locale
        queryItems["language"] = resolvedLocaleState.language
        queryItems["localeRevision"] = resolvedLocaleState.revision
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
        if let bundleMetadata {
            props["__lynxBundleMeta"] = bundleMetadata
        } else {
            props.removeValue(forKey: "__lynxBundleMeta")
        }
        if let nativeTransition = request.nativeTransition {
            // 必须在 loadTemplate 之前注入，目标页首屏即可读取 transactionID 并按需
            // 调用 NativeModules.LynxShellModule.markTransitionReady。
            props["nativeTransition"] = nativeTransition.dictionary
        } else {
            props.removeValue(forKey: "nativeTransition")
        }
        return props
    }

    static func applyLocale(_ state: LynxLocaleState, to props: inout [String: Any]) {
        props["__lynxShellLocale"] = state.dictionary
        props["locale"] = state.locale
        props["effectiveLocale"] = state.locale
        props["formatLocale"] = state.locale
        props["language"] = state.language
        props["appLocale"] = state.appLocale ?? NSNull()
        props["appLocaleOverride"] = state.appLocale ?? NSNull()
        props["appLanguage"] = state.language
        props["systemLocale"] = state.systemLocale
        props["localeRevision"] = state.revision
        props["localeSource"] = state.source
        props["localeStatus"] = state.status
        props["direction"] = state.direction
    }

    static func applyLayout(_ snapshot: ShellLayoutSnapshot, to props: inout [String: Any]) {
        let measurement = snapshot.measurement
        props["__lynxShellLayout"] = snapshot.dictionary
        props["screenWidth"] = measurement.screenWidth
        props["screenHeight"] = measurement.screenHeight
        props["viewportWidth"] = measurement.viewportWidth
        props["viewportHeight"] = measurement.viewportHeight
        props["density"] = measurement.density
        props["safeAreaTop"] = measurement.safeAreaTop
        props["safeAreaBottom"] = measurement.safeAreaBottom
        props["safeAreaLeft"] = measurement.safeAreaLeft
        props["safeAreaRight"] = measurement.safeAreaRight
        props["topHeight"] = measurement.safeAreaTop
        props["bottomHeight"] = measurement.safeAreaBottom
        props["statusBarHeight"] = measurement.safeAreaTop
        props["navigationBarHeight"] = measurement.safeAreaBottom
        props["isNotchScreen"] = measurement.safeAreaTop > 20
        props["layoutRevision"] = snapshot.revision
    }
}
