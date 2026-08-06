import Foundation

/**
 * 兼容 lynxshell、Sparkling hybrid、Explorer 本地地址、HTTPS 与 App Bundle 路由。
 *
 * 为方便从已有 Sparkling 页面迁移，解析器同时接受 snake_case 与 camelCase 参数。
 */
enum LynxRouteParser {
    private static let explorerLocalPrefix = "file://lynx?local://"

    static func request(from route: String, optionsJSON: String = "{}") throws -> LynxPageRequest {
        let options = try decodeObject(optionsJSON, field: "options")
        let base: LynxPageRequest

        if route.contains("://") {
            base = try requestFromURL(route)
        } else {
            base = defaultRequest(bundleURL: normalizeBundle(route))
        }
        return try applying(options: options, to: base).validated()
    }

    static func request(
        bundleURL: String,
        title: String,
        initialDataJSON: String,
        globalPropsJSON: String,
        fullscreen: Bool,
        allowHTTPInDebug: Bool
    ) throws -> LynxPageRequest {
        try LynxPageRequest(
            bundleURL: normalizeBundle(bundleURL),
            routeKey: normalizeBundle(bundleURL),
            title: title.isEmpty ? "Lynx" : title,
            initialData: decodeObject(initialDataJSON, field: "initData"),
            globalProps: decodeObject(globalPropsJSON, field: "globalProps"),
            fullscreen: fullscreen,
            showNavigationBar: !fullscreen,
            hideStatusBar: false,
            backGestureEnabled: true,
            allowHTTPInDebug: allowHTTPInDebug,
            orientation: .system,
            backgroundColor: "#FFFFFF",
            widthInPhysicalPixels: nil,
            heightInPhysicalPixels: nil
        ).validated()
    }

    private static func requestFromURL(_ route: String) throws -> LynxPageRequest {
        // Explorer 的 file://lynx?local:// 不是标准 URL 结构，必须先按原字符串拆解。
        if route.lowercased().hasPrefix(explorerLocalPrefix) {
            return try requestFromExplorerLocal(route)
        }
        guard let components = URLComponents(string: route) else {
            throw LynxRouteError.unsupportedURL(route)
        }
        let scheme = components.scheme?.lowercased() ?? ""
        let host = components.host?.lowercased() ?? ""
        var query: [String: String] = [:]
        // 同名参数按最后一个值生效，避免 Dictionary(uniqueKeysWithValues:) 重复 key 崩溃。
        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }

        if scheme == "lynxshell" || (scheme == "hybrid" && host == "lynxview_page") {
            guard let rawBundle = first(query, keys: ["url", "bundle"]), !rawBundle.isEmpty else {
                throw LynxRouteError.missingBundle
            }
            return try requestFromQuery(bundleURL: normalizeBundle(rawBundle), query: query)
        }

        if ["assets", "https", "http"].contains(scheme) {
            return try requestFromQuery(bundleURL: route, query: query)
        }
        throw LynxRouteError.unsupportedURL(route)
    }

    /**
     * `file://lynx?local://main.lynx.bundle?fullscreen=true` 的第一个问号属于协议，
     * 第二个问号才是页面参数，URLComponents 无法直接表达这层含义。
     */
    private static func requestFromExplorerLocal(_ route: String) throws -> LynxPageRequest {
        let start = route.index(route.startIndex, offsetBy: explorerLocalPrefix.count)
        let payload = String(route[start...])
        let pieces = payload.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(pieces.first ?? "").removingPercentEncoding ?? String(pieces.first ?? "")
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LynxRouteError.missingBundle
        }
        let query = pieces.count > 1 ? parseEncodedQuery(String(pieces[1])) : [:]
        let bundle = explorerLocalPrefix + stripRelativePrefix(path)
        return try requestFromQuery(bundleURL: bundle, query: query)
    }

    private static func requestFromQuery(
        bundleURL: String,
        query: [String: String]
    ) throws -> LynxPageRequest {
        let fullscreen = bool(first(query, keys: ["fullscreen"]), default: true)
        let hiddenNavigation = bool(
            first(query, keys: ["hidden_nav", "hide_nav_bar", "hideNavigationBar"]),
            default: false
        )
        let explicitNavigation = first(query, keys: ["showNavigationBar", "showToolbar"])
        let showNavigationBar = explicitNavigation.map { !fullscreen && bool($0, default: true) }
            ?? (!fullscreen && !hiddenNavigation)
        let hideStatusBar = bool(
            first(query, keys: ["hide_status_bar", "hideStatusBar"]),
            default: false
        )
        let backGestureEnabled = bool(
            first(query, keys: ["backGestureEnabled", "back_gesture_enabled"]),
            default: true
        )
        let title = first(query, keys: ["title"])?.nonEmpty ?? "Lynx"
        let initialData = try decodeObject(
            first(query, keys: ["initData", "initialData", "initial_data"]) ?? "{}",
            field: "initData"
        )
        var globalProps = try decodeObject(
            first(query, keys: ["globalProps", "global_props"]) ?? "{}",
            field: "globalProps"
        )
        // Sparkling 页面通过 lynx.__globalProps.queryItems 读取当前路由来源与参数。
        globalProps["queryItems"] = query
        let allowHTTPInDebug = bool(
            first(query, keys: ["allowHTTPInDebug", "allowHttpInDebug", "allow_http_in_debug"]),
            default: false
        )
        let orientation = parseOrientation(first(query, keys: ["orientation", "screen_orientation"]))
        let backgroundColor = normalizeColor(
            first(
                query,
                keys: ["backgroundColor", "background_color", "container_bg_color"]
            ) ?? "#FFFFFF"
        )
        let widthInPhysicalPixels = first(query, keys: ["width", "width_px"])
            .flatMap { Double($0) }
            .map { CGFloat($0) }
        let heightInPhysicalPixels = first(query, keys: ["height", "height_px"])
            .flatMap { Double($0) }
            .map { CGFloat($0) }
        let requestedAppId = first(query, keys: ["lynxAppId", "appId", "lynx_app_id"])
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
        // HTTPS 始终是 Direct Remote；即使 URL query 带 appId 也不允许隐式进入 OTA。
        let otaAppId = RemoteBundlePolicy.isRemote(bundleURL) ? nil : requestedAppId
        let otaBundleName = otaAppId.flatMap { _ in
            first(query, keys: ["bundleName", "bundle_name"])?
                .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? bundleURL.components(separatedBy: "/").last?.nonEmpty
        }

        return LynxPageRequest(
            bundleURL: bundleURL,
            lynxAppId: otaBundleName == nil ? nil : otaAppId,
            bundleName: otaBundleName,
            routeKey: first(query, keys: ["routeKey", "route_key"])?.nonEmpty
                ?? otaBundleName
                ?? bundleURL,
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
            heightInPhysicalPixels: heightInPhysicalPixels
        )
    }

    private static func applying(
        options: [String: Any],
        to base: LynxPageRequest
    ) throws -> LynxPageRequest {
        let fullscreenOption = firstBool(options, keys: ["fullscreen"])
        let fullscreen = fullscreenOption ?? base.fullscreen

        var showNavigationBar = base.showNavigationBar
        if fullscreenOption != nil {
            showNavigationBar = fullscreen ? false : (base.fullscreen ? true : base.showNavigationBar)
        }
        if let visible = firstBool(options, keys: ["showNavigationBar", "showToolbar"]) {
            showNavigationBar = !fullscreen && visible
        }
        if let hidden = firstBool(
            options,
            keys: ["hidden_nav", "hide_nav_bar", "hideNavigationBar"]
        ) {
            showNavigationBar = !fullscreen && !hidden
        }

        // fullscreen 只控制 edge-to-edge；隐藏状态栏必须使用独立参数显式声明。
        var hideStatusBar = base.hideStatusBar
        if let hidden = firstBool(options, keys: ["hideStatusBar", "hide_status_bar"]) {
            hideStatusBar = hidden
        }
        let initialData = try firstObject(
            options,
            keys: ["initData", "initialData", "initial_data"],
            fallback: base.initialData,
            field: "initData"
        )
        let globalProps = try firstObject(
            options,
            keys: ["globalProps", "global_props"],
            fallback: base.globalProps,
            field: "globalProps"
        )
        let allowHTTPInDebug = firstBool(
            options,
            keys: ["allowHTTPInDebug", "allowHttpInDebug", "allow_http_in_debug"]
        ) ?? base.allowHTTPInDebug
        let orientation = firstString(options, keys: ["orientation", "screen_orientation"])
            .map(parseOrientation) ?? base.orientation
        let backgroundColor = normalizeColor(
            firstString(
                options,
                keys: ["backgroundColor", "background_color", "container_bg_color"]
            )
                ?? base.backgroundColor
        )
        let widthInPhysicalPixels = firstNumber(options, keys: ["width", "width_px"])
            .map { CGFloat(truncating: $0) } ?? base.widthInPhysicalPixels
        let heightInPhysicalPixels = firstNumber(options, keys: ["height", "height_px"])
            .map { CGFloat(truncating: $0) } ?? base.heightInPhysicalPixels
        let requestedAppId = firstString(options, keys: ["lynxAppId", "appId", "lynx_app_id"])
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
            ?? base.lynxAppId
        let requestedBundleName = firstString(options, keys: ["bundleName", "bundle_name"])
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
        let otaAppId = RemoteBundlePolicy.isRemote(base.bundleURL) ? nil : requestedAppId
        let otaBundleName = otaAppId.flatMap { _ in
            requestedBundleName
                ?? base.bundleName
                ?? base.bundleURL.components(separatedBy: "/").last?.nonEmpty
        }

        return LynxPageRequest(
            bundleURL: base.bundleURL,
            lynxAppId: otaBundleName == nil ? nil : otaAppId,
            bundleName: otaBundleName,
            routeKey: firstString(options, keys: ["routeKey", "route_key"])?.nonEmpty
                ?? otaBundleName
                ?? base.routeKey,
            title: firstString(options, keys: ["title"])?.nonEmpty ?? base.title,
            initialData: initialData,
            globalProps: globalProps,
            fullscreen: fullscreen,
            showNavigationBar: showNavigationBar,
            hideStatusBar: hideStatusBar,
            backGestureEnabled: firstBool(
                options,
                keys: ["backGestureEnabled", "back_gesture_enabled"]
            ) ?? base.backGestureEnabled,
            allowHTTPInDebug: allowHTTPInDebug,
            orientation: orientation,
            backgroundColor: backgroundColor,
            widthInPhysicalPixels: widthInPhysicalPixels,
            heightInPhysicalPixels: heightInPhysicalPixels
        )
    }

    private static func defaultRequest(bundleURL: String) -> LynxPageRequest {
        LynxPageRequest(
            bundleURL: bundleURL,
            routeKey: bundleURL,
            title: "Lynx",
            initialData: [:],
            globalProps: [:],
            fullscreen: true,
            showNavigationBar: false,
            hideStatusBar: false,
            backGestureEnabled: true,
            allowHTTPInDebug: false,
            orientation: .system,
            backgroundColor: "#FFFFFF",
            widthInPhysicalPixels: nil,
            heightInPhysicalPixels: nil
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

    private static func firstObject(
        _ values: [String: Any],
        keys: [String],
        fallback: [String: Any],
        field: String
    ) throws -> [String: Any] {
        guard let value = firstValue(values, keys: keys) else { return fallback }
        if let object = value as? [String: Any] { return object }
        if let json = value as? String { return try decodeObject(json, field: field) }
        throw LynxRouteError.invalidJSON(field)
    }

    private static func normalizeBundle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") || trimmed.lowercased().hasPrefix(explorerLocalPrefix) {
            return trimmed
        }
        let path = stripRelativePrefix(trimmed)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.lowercased().hasPrefix("bundles/")
            ? "assets://Bundles/\(path.split(separator: "/").dropFirst().joined(separator: "/"))"
            : "assets://Bundles/\(path)"
    }

    private static func stripRelativePrefix(_ value: String) -> String {
        var result = value.replacingOccurrences(of: "\\", with: "/")
        while result.hasPrefix("./") { result.removeFirst(2) }
        return result
    }

    private static func normalizeColor(_ value: String) -> String {
        value.hasPrefix("#") ? value : "#\(value)"
    }

    private static func parseOrientation(_ value: String?) -> LynxPageRequest.Orientation {
        switch value?.lowercased() {
        case "portrait", "vertical": return .portrait
        case "landscape", "horizontal": return .landscape
        default: return .system
        }
    }

    private static func parseEncodedQuery(_ value: String) -> [String: String] {
        var result: [String: String] = [:]
        for item in value.split(separator: "&", omittingEmptySubsequences: true) {
            let pieces = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let rawKey = String(pieces.first ?? "")
            let rawValue = pieces.count > 1 ? String(pieces[1]) : ""
            let key = rawKey.removingPercentEncoding ?? rawKey
            let decoded = rawValue.removingPercentEncoding ?? rawValue
            result[key] = decoded
        }
        return result
    }

    private static func first(_ values: [String: String], keys: [String]) -> String? {
        for key in keys {
            if let value = values[key] { return value }
        }
        return nil
    }

    private static func firstValue(_ values: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = values[key], !(value is NSNull) { return value }
        }
        return nil
    }

    private static func firstString(_ values: [String: Any], keys: [String]) -> String? {
        guard let value = firstValue(values, keys: keys) else { return nil }
        if let string = value as? String { return string }
        return String(describing: value)
    }

    private static func firstNumber(_ values: [String: Any], keys: [String]) -> NSNumber? {
        guard let value = firstValue(values, keys: keys) else { return nil }
        if let number = value as? NSNumber { return number }
        if let string = value as? String, let double = Double(string) { return NSNumber(value: double) }
        return nil
    }

    private static func firstBool(_ values: [String: Any], keys: [String]) -> Bool? {
        guard let value = firstValue(values, keys: keys) else { return nil }
        if let boolValue = value as? Bool { return boolValue }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            if ["1", "true", "yes"].contains(string.lowercased()) { return true }
            if ["0", "false", "no"].contains(string.lowercased()) { return false }
        }
        return nil
    }

    private static func bool(_ value: String?, default fallback: Bool) -> Bool {
        guard let value else { return fallback }
        return ["1", "true", "yes"].contains(value.lowercased())
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
