import AVFoundation
import Foundation
import Network
import SafariServices
import UIKit
import WebKit

/** UIKit/Foundation/Network 对译：设备、应用、系统栏、网络和浏览器能力。 */
enum LynxNativeSystemCapabilities {
    typealias Completion = (LynxNativeCapabilityResult) -> Void
    typealias EventSender = (String) -> Void

    private static let supportedPlugins: Set<String> = [
        "Device", "App", "AppLauncher", "Preferences", "Network", "CapacitorHttp",
        "CapacitorCookies", "Browser", "InAppBrowser", "StatusBar", "SystemBars",
        "ScreenOrientation", "ScreenReader", "TextZoom", "Keyboard", "SplashScreen",
        "PrivacyScreen", "KeepAwake", "SafeArea",
    ]
    private static let preferences = UserDefaults.standard
    private static let networkLock = NSLock()
    private static var networkMonitor: NWPathMonitor?
    private static var latestNetworkPath: NWPath?
    private static var activeInAppBrowser: UIViewController?
    private static var privacyOverlay: UIView?
    private static var splashOverlay: UIView?
    private static var privacyEnabled = false
    private static var privacyObservers: [NSObjectProtocol] = []

    static func dispatch(
        _ call: LynxNativeCapabilityCall,
        presenter: UIViewController?,
        eventSender: EventSender?,
        completion: @escaping Completion
    ) -> Bool {
        guard supportedPlugins.contains(call.pluginId) else { return false }
        let run = {
            switch call.pluginId {
            case "Device": dispatchDevice(call, completion: completion)
            case "App": dispatchApp(call, completion: completion)
            case "AppLauncher": dispatchAppLauncher(call, completion: completion)
            case "Preferences": dispatchPreferences(call, completion: completion)
            case "Network": dispatchNetwork(call, completion: completion)
            case "CapacitorHttp": dispatchHTTP(call, completion: completion)
            case "CapacitorCookies": dispatchCookies(call, completion: completion)
            case "Browser": dispatchBrowser(call, presenter: presenter, completion: completion)
            case "InAppBrowser": dispatchInAppBrowser(call, presenter: presenter, completion: completion)
            case "StatusBar": dispatchStatusBar(call, presenter: presenter, completion: completion)
            case "SystemBars": dispatchSystemBars(call, presenter: presenter, completion: completion)
            case "ScreenOrientation": dispatchScreenOrientation(call, presenter: presenter, completion: completion)
            case "ScreenReader": dispatchScreenReader(call, completion: completion)
            case "TextZoom": dispatchTextZoom(call, completion: completion)
            case "Keyboard": dispatchKeyboard(call, presenter: presenter, completion: completion)
            case "SplashScreen": dispatchSplashScreen(call, presenter: presenter, completion: completion)
            case "PrivacyScreen": dispatchPrivacyScreen(call, presenter: presenter, completion: completion)
            case "KeepAwake": dispatchKeepAwake(call, completion: completion)
            case "SafeArea": dispatchSafeArea(call, presenter: presenter, completion: completion)
            default: completion(.failure("UNSUPPORTED", "\(call.pluginId).\(call.methodName) 尚未接入当前 iOS Module"))
            }
        }
        _ = eventSender
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
        return true
    }

    static func release() {
        activeInAppBrowser?.dismiss(animated: false)
        activeInAppBrowser = nil
        networkLock.withLock {
            networkMonitor?.cancel()
            networkMonitor = nil
            latestNetworkPath = nil
        }
        removeOverlay(&privacyOverlay)
        removeOverlay(&splashOverlay)
        privacyObservers.forEach(NotificationCenter.default.removeObserver)
        privacyObservers.removeAll()
        privacyEnabled = false
    }

    // MARK: - Device / App / Preferences

    private static func dispatchDevice(_ call: LynxNativeCapabilityCall, completion: @escaping Completion) {
        switch call.methodName {
        case "getInfo":
            let device = UIDevice.current
            completion(.success([
                "model": device.model,
                "platform": "ios",
                "operatingSystem": "ios",
                "osVersion": device.systemVersion,
                "manufacturer": "Apple",
                "isVirtual": isSimulator,
                "webViewVersion": NSNull(),
            ]))
        case "getId":
            completion(.success(["identifier": UIDevice.current.identifierForVendor?.uuidString ?? NSNull()]))
        case "getBatteryInfo":
            let device = UIDevice.current
            device.isBatteryMonitoringEnabled = true
            let level = device.batteryLevel
            let charging: Any
            switch device.batteryState {
            case .charging: charging = true
            case .full: charging = true
            case .unplugged: charging = false
            default: charging = NSNull()
            }
            completion(.success([
                "batteryLevel": level >= 0 ? level : NSNull(),
                "isCharging": charging,
                "batteryState": batteryState(device.batteryState),
            ]))
        case "getLanguageCode": completion(.success(["value": Locale.preferredLanguages.first.flatMap { $0.split(separator: "-").first.map(String.init) } ?? Locale.current.languageCode ?? "en"]))
        case "getLanguageTag": completion(.success(["value": Locale.preferredLanguages.first ?? Locale.current.identifier]))
        default: completion(.failure("UNSUPPORTED", "Device.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    private static func dispatchApp(_ call: LynxNativeCapabilityCall, completion: @escaping Completion) {
        switch call.methodName {
        case "getInfo":
            let info = Bundle.main.infoDictionary ?? [:]
            let rawBuild = string(info["CFBundleVersion"])
            let build: Any = Int64(rawBuild) ?? rawBuild
            completion(.success([
                "name": string(info["CFBundleDisplayName"] ?? info["CFBundleName"]),
                "id": Bundle.main.bundleIdentifier ?? "",
                "version": string(info["CFBundleShortVersionString"]),
                "build": build,
            ]))
        case "getState":
            completion(.success(["isActive": UIApplication.shared.applicationState == .active]))
        case "getLaunchUrl":
            completion(.success(["url": LynxNativeCapabilityRuntime.globalLaunchURL() ?? NSNull()]))
        default: completion(.failure("UNSUPPORTED", "App.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    private static func dispatchAppLauncher(_ call: LynxNativeCapabilityCall, completion: @escaping Completion) {
        guard let url = urlValue(call.options["url"]) else {
            completion(.failure("INVALID_ARGUMENT", "url 不能为空或不是合法 URL"))
            return
        }
        switch call.methodName {
        case "canOpenUrl": completion(.success(["value": UIApplication.shared.canOpenURL(url)]))
        case "openUrl":
            UIApplication.shared.open(url, options: [:]) { opened in
                if opened { completion(.success(["opened": true])) }
                else { completion(.failure("NO_HANDLER", "系统没有可以打开该 URL 的应用", details: ["url": url.absoluteString])) }
            }
        default: completion(.failure("UNSUPPORTED", "AppLauncher.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    private static func dispatchPreferences(_ call: LynxNativeCapabilityCall, completion: @escaping Completion) {
        let key = string(call.options["key"])
        guard !key.isEmpty || call.methodName == "keys" else {
            completion(.failure("INVALID_ARGUMENT", "key 不能为空"))
            return
        }
        let prefix = "lynx.native."
        switch call.methodName {
        case "set":
            guard let rawValue = call.options["value"], !(rawValue is NSNull) else {
                completion(.failure("INVALID_ARGUMENT", "Preferences.set 的 value 不能为空"))
                return
            }
            let value = string(rawValue)
            preferences.set(value, forKey: prefix + key)
            completion(.success(["saved": true]))
        case "get": completion(.success(["value": preferences.object(forKey: prefix + key) ?? NSNull()]))
        case "keys":
            completion(.success(["keys": preferences.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }.sorted()]))
        case "remove":
            preferences.removeObject(forKey: prefix + key)
            completion(.success(["removed": true]))
        default: completion(.failure("UNSUPPORTED", "Preferences.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    // MARK: - Network / HTTP / Cookies

    private static func dispatchNetwork(_ call: LynxNativeCapabilityCall, completion: @escaping Completion) {
        guard call.methodName == "getStatus" else {
            completion(.failure("UNSUPPORTED", "Network.\(call.methodName) 尚未接入当前 iOS Module"))
            return
        }
        let deliver: (NWPath) -> Void = { path in completion(.success(networkData(path))) }
        networkLock.lock()
        if let path = latestNetworkPath {
            networkLock.unlock()
            deliver(path)
            return
        }
        if networkMonitor == nil {
            let monitor = NWPathMonitor()
            networkMonitor = monitor
            monitor.pathUpdateHandler = { path in networkLock.withLock { latestNetworkPath = path } }
            monitor.start(queue: DispatchQueue(label: "lynx.native.network"))
        }
        let monitor = networkMonitor
        networkLock.unlock()
        let timeout = DispatchWorkItem {
            let path = networkLock.withLock { latestNetworkPath }
            if let path { deliver(path) }
            else { completion(.failure("NETWORK_STATUS_UNAVAILABLE", "NWPathMonitor 尚未返回网络状态")) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
        _ = monitor
    }

    private static func dispatchHTTP(_ call: LynxNativeCapabilityCall, completion: @escaping Completion) {
        guard let rawURL = stringOptional(call.options["url"]), let url = URL(string: rawURL), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            completion(.failure("INVALID_ARGUMENT", "只支持合法的 http/https URL"))
            return
        }
        let method: String
        switch call.methodName {
        case "get": method = "GET"
        case "post": method = "POST"
        case "request": method = string(call.options["method"], default: "GET").uppercased()
        default:
            completion(.failure("UNSUPPORTED", "CapacitorHttp.\(call.methodName) 尚未接入当前 iOS Module"))
            return
        }
        guard ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"].contains(method) else {
            completion(.failure("INVALID_ARGUMENT", "不支持的 HTTP method: \(method)"))
            return
        }
        guard let requestURL = appendQuery(url, params: call.options["params"], encode: bool(call.options["shouldEncodeUrlParams"], default: true)) else {
            completion(.failure("INVALID_ARGUMENT", "params 无法编码"))
            return
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        guard let connectTimeout = timeoutMillis(call.options["connectTimeout"], default: 10_000),
              let readTimeout = timeoutMillis(call.options["readTimeout"], default: 15_000) else {
            completion(.failure("INVALID_ARGUMENT", "connectTimeout/readTimeout 必须是 0 到 120000 的毫秒数"))
            return
        }
        let requestTimeout = [connectTimeout, readTimeout].filter { $0 > 0 }.min() ?? 120_000
        request.timeoutInterval = requestTimeout / 1000
        if let headers = call.options["headers"] as? [String: Any] {
            headers.forEach { request.setValue(string($0.value), forHTTPHeaderField: $0.key) }
        }
        if let data = call.options["data"], !(data is NSNull), method != "GET", method != "HEAD" {
            if let rawData = data as? String {
                request.httpBody = rawData.data(using: .utf8)
            } else if JSONSerialization.isValidJSONObject(data) {
                request.httpBody = try? JSONSerialization.data(withJSONObject: data)
            } else {
                request.httpBody = string(data).data(using: .utf8)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = readTimeout > 0 ? readTimeout / 1000 : 120
        configuration.timeoutIntervalForResource = max(
            connectTimeout > 0 ? connectTimeout / 1000 : 120,
            readTimeout > 0 ? readTimeout / 1000 : 120
        )
        let session = URLSession(configuration: configuration, delegate: bool(call.options["disableRedirects"], default: false) ? NoRedirectDelegate() : nil, delegateQueue: nil)
        session.dataTask(with: request) { data, response, error in
            defer { session.invalidateAndCancel() }
            if let error {
                let nsError = error as NSError
                completion(.failure(nsError.code == NSURLErrorTimedOut ? "TIMEOUT" : "HTTP_ERROR", nsError.localizedDescription))
                return
            }
            let bytes = data ?? Data()
            guard bytes.count <= 10 * 1024 * 1024 else {
                completion(.failure("RESPONSE_TOO_LARGE", "HTTP response 超过 10 MB 限制"))
                return
            }
            let http = response as? HTTPURLResponse
            let headers = (http?.allHeaderFields ?? [:]).reduce(into: [String: Any]()) { result, item in result[String(describing: item.key)] = String(describing: item.value) }
            completion(.success([
                "status": http?.statusCode ?? 0,
                "headers": headers,
                "url": response?.url?.absoluteString ?? requestURL.absoluteString,
                "data": responseData(bytes, type: string(call.options["responseType"])),
                "timeout": ["connectTimeout": connectTimeout, "readTimeout": readTimeout, "connectTimeoutApplied": false],
            ]))
        }.resume()
    }

    private static func dispatchCookies(_ call: LynxNativeCapabilityCall, completion: @escaping Completion) {
        let rawURL = string(call.options["url"])
        guard call.methodName == "clearAllCookies" || (!rawURL.isEmpty && URL(string: rawURL) != nil) else {
            completion(.failure("INVALID_ARGUMENT", "url 不能为空"))
            return
        }
        let storage = HTTPCookieStorage.shared
        switch call.methodName {
        case "setCookie":
            guard let url = URL(string: rawURL), !string(call.options["key"]).isEmpty else {
                completion(.failure("INVALID_ARGUMENT", "setCookie 需要合法 url 和 key")); return
            }
            let properties: [HTTPCookiePropertyKey: Any] = [
                .domain: string(call.options["domain"], default: url.host ?? ""),
                .path: string(call.options["path"], default: "/"),
                .name: string(call.options["key"]),
                .value: string(call.options["value"]),
            ]
            guard let cookie = HTTPCookie(properties: properties) else {
                completion(.failure("INVALID_ARGUMENT", "Cookie 参数无效")); return
            }
            storage.setCookie(cookie)
            completion(.success(["saved": true]))
        case "getCookies":
            guard let url = URL(string: rawURL) else { completion(.failure("INVALID_ARGUMENT", "url 无效")); return }
            let cookies = storage.cookies(for: url) ?? []
            completion(.success(["cookies": cookies.reduce(into: [String: String]()) { $0[$1.name] = $1.value }]))
        case "clearAllCookies":
            storage.cookies?.forEach(storage.deleteCookie)
            completion(.success(["cleared": true]))
        default: completion(.failure("UNSUPPORTED", "CapacitorCookies.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    // MARK: - Browser / InAppBrowser

    private static func dispatchBrowser(_ call: LynxNativeCapabilityCall, presenter: UIViewController?, completion: @escaping Completion) {
        switch call.methodName {
        case "open":
            guard let url = urlValue(call.options["url"]) else { completion(.failure("INVALID_ARGUMENT", "url 不能为空或不是合法 URL")); return }
            UIApplication.shared.open(url, options: [:]) { opened in
                opened ? completion(.success(["opened": true])) : completion(.failure("NO_HANDLER", "系统没有可用浏览器处理 URL"))
            }
        case "close": completion(.failure("UNSUPPORTED", "Browser.close 由外部浏览器管理，当前 Android/iOS Module 不提供关闭能力"))
        default: completion(.failure("UNSUPPORTED", "Browser.\(call.methodName) 尚未接入当前 iOS Module"))
        }
        _ = presenter
    }

    private static func dispatchInAppBrowser(_ call: LynxNativeCapabilityCall, presenter: UIViewController?, completion: @escaping Completion) {
        guard let presenter, LynxNativeCapabilitySupport.isUsable(presenter) else { completion(.failure("SCENE_UNAVAILABLE", "没有可展示 InAppBrowser 的前台 UIViewController")); return }
        switch call.methodName {
        case "openInWebView":
            guard let url = urlValue(call.options["url"]) else { completion(.failure("INVALID_ARGUMENT", "url 不能为空或不是合法 URL")); return }
            guard activeInAppBrowser == nil else { completion(.failure("BUSY", "已有 InAppBrowser 正在显示")); return }
            let controller = LynxNativeWebViewController(url: url)
            activeInAppBrowser = controller
            controller.onDismiss = { activeInAppBrowser = nil }
            presenter.present(controller, animated: true) { completion(.success(["opened": true, "url": url.absoluteString])) }
        case "close":
            let current = activeInAppBrowser
            activeInAppBrowser = nil
            current?.dismiss(animated: true)
            completion(.success(["closed": current != nil]))
        default: completion(.failure("UNSUPPORTED", "InAppBrowser.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    // MARK: - System UI

    private static func dispatchStatusBar(_ call: LynxNativeCapabilityCall, presenter: UIViewController?, completion: @escaping Completion) {
        guard let presenter else { completion(.failure("SCENE_UNAVAILABLE", "没有可用的页面控制器")); return }
        if let host = presenter as? LynxCapacitorStatusBarHost {
            switch call.methodName {
            case "getInfo": completion(.success(host.capacitorStatusBarInfo()))
            case "setStyle":
                let style = string(call.options["style"], default: "DEFAULT").uppercased()
                host.setCapacitorStatusBarStyle(style) ? completion(.success(["style": style])) : completion(.failure("INVALID_ARGUMENT", "StatusBar.style 无效"))
            case "hide": host.setCapacitorStatusBarVisible(false); completion(.success(["visible": false]))
            case "show": host.setCapacitorStatusBarVisible(true); completion(.success(["visible": true]))
            default: completion(.failure("UNSUPPORTED", "StatusBar.\(call.methodName) 尚未接入当前 iOS Module"))
            }
            return
        }
        switch call.methodName {
        case "getInfo": completion(.success(["visible": !presenter.prefersStatusBarHidden, "style": statusBarStyleName(presenter.preferredStatusBarStyle)]))
        case "setStyle", "hide", "show": completion(.failure("UNSUPPORTED_SYSTEM_UI", "当前页面没有实现 Lynx native status bar host"))
        default: completion(.failure("UNSUPPORTED", "StatusBar.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    private static func dispatchSystemBars(_ call: LynxNativeCapabilityCall, presenter: UIViewController?, completion: @escaping Completion) {
        guard call.methodName == "setStyle", let presenter else { completion(.failure("SCENE_UNAVAILABLE", "没有可用的页面控制器")); return }
        guard let host = presenter as? LynxCapacitorSystemBarsHost else { completion(.failure("UNSUPPORTED_SYSTEM_UI", "当前页面没有实现 Lynx native system bars host")); return }
        let style = string(call.options["style"], default: "DEFAULT").uppercased()
        host.setCapacitorSystemBarsStyle(style) ? completion(.success(["style": style])) : completion(.failure("INVALID_ARGUMENT", "SystemBars.style 无效"))
    }

    private static func dispatchScreenOrientation(_ call: LynxNativeCapabilityCall, presenter: UIViewController?, completion: @escaping Completion) {
        guard let presenter else { completion(.failure("SCENE_UNAVAILABLE", "没有可用的页面控制器")); return }
        guard let host = presenter as? LynxCapacitorOrientationHost else { completion(.failure("UNSUPPORTED_SYSTEM_ORIENTATION", "当前页面没有实现 orientation host")); return }
        switch call.methodName {
        case "orientation": completion(.success(["type": orientationName(presenter.view.window?.windowScene?.interfaceOrientation ?? .unknown)]))
        case "lock":
            let value = string(call.options["orientation"], default: "any")
            host.applyCapacitorOrientation(value) ? completion(.success(["orientation": value])) : completion(.failure("INVALID_ARGUMENT", "orientation 无效"))
        case "unlock": host.clearCapacitorOrientation(); completion(.success(["unlocked": true]))
        default: completion(.failure("UNSUPPORTED", "ScreenOrientation.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    private static func dispatchScreenReader(_ call: LynxNativeCapabilityCall, completion: @escaping Completion) {
        switch call.methodName {
        case "isEnabled": completion(.success(["value": UIAccessibility.isVoiceOverRunning]))
        case "speak":
            let text = string(call.options["value"] ?? call.options["text"])
            guard !text.isEmpty else { completion(.failure("INVALID_ARGUMENT", "speak 文本不能为空")); return }
            UIAccessibility.post(notification: .announcement, argument: text)
            completion(.success(["spoken": true, "implementation": "VoiceOverAnnouncement"]))
        default: completion(.failure("UNSUPPORTED", "ScreenReader.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    private static func dispatchTextZoom(_ call: LynxNativeCapabilityCall, completion: @escaping Completion) {
        switch call.methodName {
        case "getPreferred", "get": completion(.success(["value": preferredTextZoom(), "source": "UIContentSizeCategory"]))
        case "set": completion(.failure("UNSUPPORTED_TEXT_ZOOM", "Lynx 原生视图没有公开的全局 fontScale 设置接口"))
        default: completion(.failure("UNSUPPORTED", "TextZoom.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    private static func dispatchKeyboard(_ call: LynxNativeCapabilityCall, presenter: UIViewController?, completion: @escaping Completion) {
        guard let presenter else { completion(.failure("SCENE_UNAVAILABLE", "没有可用的页面控制器")); return }
        switch call.methodName {
        case "getResizeMode": completion(.success(["resizeMode": "native"]))
        case "hide": presenter.view.endEditing(true); completion(.success(["hidden": true]))
        case "setStyle": completion(.failure("UNSUPPORTED", "Keyboard.setStyle 在 Android 事实源中未接入当前 Module"))
        default: completion(.failure("UNSUPPORTED", "Keyboard.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    private static func dispatchSplashScreen(_ call: LynxNativeCapabilityCall, presenter: UIViewController?, completion: @escaping Completion) {
        guard call.methodName == "hide" || call.methodName == "show" else { completion(.failure("UNSUPPORTED", "SplashScreen.\(call.methodName) 尚未接入当前 iOS Module")); return }
        guard let presenter else { completion(.failure("SCENE_UNAVAILABLE", "没有可用的页面控制器")); return }
        if call.methodName == "show" {
            if splashOverlay == nil {
                let overlay = UIView(frame: presenter.view.bounds)
                overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                overlay.backgroundColor = .systemBackground
                presenter.view.addSubview(overlay)
                splashOverlay = overlay
            }
            splashOverlay?.isHidden = false
        } else {
            splashOverlay?.isHidden = true
        }
        completion(.success(["hidden": call.methodName == "hide", "implementation": "RuntimeOverlay"]))
    }

    private static func dispatchPrivacyScreen(_ call: LynxNativeCapabilityCall, presenter: UIViewController?, completion: @escaping Completion) {
        switch call.methodName {
        case "isEnabled": completion(.success(["value": privacyEnabled, "enforcement": "captureDetectionOverlayOnly"]))
        case "enable":
            privacyEnabled = true
            if let presenter, privacyOverlay == nil {
                let overlay = UIView(frame: presenter.view.bounds)
                overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                overlay.backgroundColor = .systemBackground
                overlay.isHidden = true
                presenter.view.addSubview(overlay)
                privacyOverlay = overlay
            }
            installPrivacyObservers()
            updatePrivacyOverlay()
            completion(.success(["enabled": true, "enforcement": "captureDetectionOverlayOnly"]))
        case "disable":
            privacyEnabled = false
            privacyObservers.forEach(NotificationCenter.default.removeObserver)
            privacyObservers.removeAll()
            removeOverlay(&privacyOverlay)
            completion(.success(["enabled": false]))
        default: completion(.failure("UNSUPPORTED", "PrivacyScreen.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    private static func dispatchKeepAwake(_ call: LynxNativeCapabilityCall, completion: @escaping Completion) {
        switch call.methodName {
        case "isSupported": completion(.success(["value": true]))
        case "isKeptAwake": completion(.success(["value": UIApplication.shared.isIdleTimerDisabled]))
        case "keepAwake": UIApplication.shared.isIdleTimerDisabled = true; completion(.success(["keptAwake": true]))
        case "allowSleep": UIApplication.shared.isIdleTimerDisabled = false; completion(.success(["keptAwake": false]))
        default: completion(.failure("UNSUPPORTED", "KeepAwake.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    private static func dispatchSafeArea(_ call: LynxNativeCapabilityCall, presenter: UIViewController?, completion: @escaping Completion) {
        guard let presenter, let host = presenter as? LynxCapacitorSystemBarsHost else { completion(.failure("UNSUPPORTED_SYSTEM_UI", "当前页面没有实现 safe area host")); return }
        switch call.methodName {
        case "setSystemBarsStyle":
            let style = string(call.options["style"], default: "DEFAULT").uppercased()
            host.setCapacitorSystemBarsStyle(style) ? completion(.success(["style": style])) : completion(.failure("INVALID_ARGUMENT", "style 无效"))
        case "hideSystemBars": host.setCapacitorSafeAreaVisible(false, type: string(call.options["type"], default: "all")) ? completion(.success(["visible": false])) : completion(.failure("INVALID_ARGUMENT", "type 无效"))
        case "showSystemBars": host.setCapacitorSafeAreaVisible(true, type: string(call.options["type"], default: "all")) ? completion(.success(["visible": true])) : completion(.failure("INVALID_ARGUMENT", "type 无效"))
        default: completion(.failure("UNSUPPORTED", "SafeArea.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    // MARK: - Helpers

    private static var isSimulator: Bool {
#if targetEnvironment(simulator)
        return true
#else
        return false
#endif
    }

    private static func string(_ value: Any?, default defaultValue: String = "") -> String {
        guard let value, !(value is NSNull) else { return defaultValue }
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return String(describing: value)
    }

    private static func stringOptional(_ value: Any?) -> String? {
        let result = string(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func bool(_ value: Any?, default defaultValue: Bool) -> Bool {
        guard let value, !(value is NSNull) else { return defaultValue }
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return ["true", "1", "yes", "on"].contains(string(value).lowercased())
    }

    private static func double(_ value: Any?, default defaultValue: Double) -> Double {
        if let value = value as? NSNumber { return value.doubleValue }
        return Double(string(value)) ?? defaultValue
    }

    private static func timeoutMillis(_ value: Any?, default defaultValue: Double) -> TimeInterval? {
        guard let value, !(value is NSNull) else { return defaultValue }
        let millis = double(value, default: .nan)
        guard millis.isFinite, millis >= 0, millis <= 120_000 else { return nil }
        return millis
    }

    private static func urlValue(_ value: Any?) -> URL? {
        guard let raw = stringOptional(value), let url = URL(string: raw), url.scheme?.isEmpty == false else { return nil }
        return url
    }

    private static func appendQuery(_ url: URL, params: Any?, encode: Bool) -> URL? {
        guard let params = params as? [String: Any], !params.isEmpty else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        for (key, raw) in params {
            if let values = raw as? [Any] {
                values.forEach { items.append(URLQueryItem(name: key, value: string($0))) }
            } else {
                items.append(URLQueryItem(name: key, value: string(raw)))
            }
        }
        if !encode { components?.percentEncodedQuery = items.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&") }
        else { components?.queryItems = items }
        return components?.url
    }

    private static func responseData(_ data: Data, type: String) -> Any {
        if ["arraybuffer", "blob"].contains(type.lowercased()) { return data.base64EncodedString() }
        let text = String(data: data, encoding: .utf8) ?? ""
        if ["text", "document"].contains(type.lowercased()) || text.isEmpty { return text }
        return (try? JSONSerialization.jsonObject(with: data)) ?? text
    }

    private static func networkData(_ path: NWPath) -> [String: Any] {
        let type: String
        if path.usesInterfaceType(.wifi) { type = "wifi" }
        else if path.usesInterfaceType(.cellular) { type = "cellular" }
        else if path.usesInterfaceType(.wiredEthernet) { type = "ethernet" }
        else if path.status == .satisfied { type = "other" }
        else { type = "none" }
        return [
            "connected": path.status == .satisfied,
            "connectionType": type,
            "isExpensive": path.isExpensive,
            "isConstrained": path.isConstrained,
        ]
    }

    private static func batteryState(_ state: UIDevice.BatteryState) -> String {
        switch state { case .charging: return "charging"; case .full: return "full"; case .unplugged: return "unplugged"; default: return "unknown" }
    }

    private static func statusBarStyleName(_ style: UIStatusBarStyle) -> String {
        if #available(iOS 13.0, *) { return style == .darkContent ? "DARK" : "LIGHT" }
        return style == .default ? "DEFAULT" : "LIGHT"
    }

    private static func orientationName(_ orientation: UIInterfaceOrientation) -> String {
        switch orientation { case .portrait: return "portrait-primary"; case .portraitUpsideDown: return "portrait-secondary"; case .landscapeLeft: return "landscape-primary"; case .landscapeRight: return "landscape-secondary"; default: return "unknown" }
    }

    private static func preferredTextZoom() -> Double {
        switch UIApplication.shared.preferredContentSizeCategory {
        case .extraSmall: return 0.82
        case .small: return 0.9
        case .medium: return 1
        case .large: return 1.1
        case .extraLarge: return 1.23
        case .extraExtraLarge: return 1.35
        case .extraExtraExtraLarge: return 1.5
        default: return 1.0
        }
    }

    private static func removeOverlay(_ overlay: inout UIView?) {
        overlay?.removeFromSuperview()
        overlay = nil
    }

    private static func installPrivacyObservers() {
        guard privacyObservers.isEmpty else { return }
        let center = NotificationCenter.default
        privacyObservers = [
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
                updatePrivacyOverlay()
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                updatePrivacyOverlay()
            },
            center.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main) { _ in
                updatePrivacyOverlay()
            },
        ]
    }

    private static func updatePrivacyOverlay() {
        let shouldHide = privacyEnabled && (
            UIApplication.shared.applicationState != .active || UIScreen.main.isCaptured
        )
        privacyOverlay?.isHidden = !shouldHide
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        _ = session; _ = task; _ = response; _ = request
        completionHandler(nil)
    }
}

private final class LynxNativeWebViewController: UIViewController, WKNavigationDelegate, UIAdaptivePresentationControllerDelegate {
    private let targetURL: URL
    private var webView: WKWebView!
    var onDismiss: (() -> Void)?

    init(url: URL) {
        targetURL = url
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }

    required init?(coder: NSCoder) { fatalError("LynxNativeWebViewController 不支持 storyboard") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        webView = WKWebView(frame: view.bounds)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        view.addSubview(webView)
        webView.load(URLRequest(url: targetURL))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentationController?.delegate = self
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if presentingViewController == nil || isBeingDismissed {
            onDismiss?()
            onDismiss = nil
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        _ = presentationController
        onDismiss?()
        onDismiss = nil
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
