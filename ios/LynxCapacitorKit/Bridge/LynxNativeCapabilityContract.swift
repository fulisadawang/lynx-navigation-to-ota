import Foundation
import Lynx
import UIKit

/**
 * Android `LynxCapacitorRuntime` 使用的 JSON envelope 在 iOS 的无依赖实现。
 *
 * 这里故意不引入 Capacitor 类型。`pluginId` 保留当前页面协议中的字符串，
 * 但它只表示本工程自己的能力命名空间，并不表示链接了 Capacitor。
 */
struct LynxNativeCapabilityCall {
    let callbackId: String
    let pluginId: String
    let methodName: String
    let options: [String: Any]
    let ownerID: String?

    init(payload: String) throws {
        guard
            let data = payload.data(using: .utf8),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw LynxNativeCapabilityError.invalidPayload
        }

        callbackId = object["callbackId"] as? String ?? "-1"
        pluginId = object["pluginId"] as? String ?? ""
        methodName = object["methodName"] as? String ?? ""
        options = object["options"] as? [String: Any] ?? [:]
        ownerID = nil
    }

    init(
        callbackId: String,
        pluginId: String,
        methodName: String,
        options: [String: Any],
        ownerID: String? = nil
    ) {
        self.callbackId = callbackId
        self.pluginId = pluginId
        self.methodName = methodName
        self.options = options
        self.ownerID = ownerID
    }

    func withOwner(_ ownerID: String) -> Self {
        Self(
            callbackId: callbackId,
            pluginId: pluginId,
            methodName: methodName,
            options: options,
            ownerID: ownerID
        )
    }
}

struct LynxNativeCapabilityResult {
    let success: Bool
    let data: [String: Any]?
    let error: [String: Any]?
    let save: Bool

    static func success(_ data: [String: Any] = [:], save: Bool = false) -> Self {
        Self(success: true, data: data, error: nil, save: save)
    }

    static func failure(_ code: String, _ message: String, details: [String: Any] = [:]) -> Self {
        var error = details
        error["code"] = code
        error["message"] = message
        return Self(success: false, data: nil, error: error, save: false)
    }

    func envelope(for call: LynxNativeCapabilityCall) -> String {
        var value: [String: Any] = [
            "callbackId": call.callbackId,
            "pluginId": call.pluginId,
            "methodName": call.methodName,
            "success": success,
            "save": save,
        ]
        if let data { value["data"] = LynxNativeJSON.normalize(data) }
        if let error { value["error"] = LynxNativeJSON.normalize(error) }
        return LynxNativeJSON.encode(value) ?? "{}"
    }
}

enum LynxNativeCapabilityError: LocalizedError {
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .invalidPayload: return "Invalid bridge payload"
        }
    }
}

enum LynxNativeJSON {
    static func encode(_ value: Any) -> String? {
        let normalized = normalize(value)
        guard JSONSerialization.isValidJSONObject(normalized),
              let data = try? JSONSerialization.data(withJSONObject: normalized, options: [])
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func normalize(_ value: Any) -> Any {
        if let date = value as? Date {
            return ISO8601DateFormatter().string(from: date)
        }
        if let url = value as? URL {
            return url.absoluteString
        }
        if let data = value as? Data {
            return data.base64EncodedString()
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues(normalize)
        }
        if let dictionary = value as? [AnyHashable: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                if let key = entry.key as? String {
                    result[key] = normalize(entry.value)
                }
            }
        }
        if let array = value as? [Any] {
            return array.map(normalize)
        }
        if let number = value as? NSNumber {
            return number
        }
        if value is NSNull { return NSNull() }
        return value
    }
}

enum LynxNativeCapabilitySupport {
    static func presenter(for context: LynxContext?) -> UIViewController? {
        guard let view = context?.getLynxView(), let window = view.window else { return nil }
        var responder: UIResponder? = view
        while let next = responder?.next {
            if let controller = next as? UIViewController {
                return topViewController(from: controller)
            }
            responder = next
        }
        return topViewController(in: window)
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes
            .flatMap(\.windows)
            .first(where: { $0.isKeyWindow })
            ?? scenes.flatMap(\.windows).first(where: { $0.windowLevel == .normal })
        var current = window?.rootViewController
        while let presented = current?.presentedViewController {
            current = presented
        }
        if let navigation = current as? UINavigationController { return navigation.visibleViewController ?? navigation }
        if let tab = current as? UITabBarController { return tab.selectedViewController ?? tab }
        return current
    }

    static func findFirstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for child in view.subviews.reversed() {
            if let responder = findFirstResponder(in: child) { return responder }
        }
        return nil
    }

    static func isUsable(_ viewController: UIViewController?) -> Bool {
        guard let viewController else { return false }
        return viewController.viewIfLoaded?.window != nil
    }

    private static func topViewController(in window: UIWindow) -> UIViewController? {
        topViewController(from: window.rootViewController)
    }

    private static func topViewController(from root: UIViewController?) -> UIViewController? {
        var current = root
        while let presented = current?.presentedViewController { current = presented }
        if let navigation = current as? UINavigationController { return navigation.visibleViewController ?? navigation }
        if let tab = current as? UITabBarController { return tab.selectedViewController ?? tab }
        return current
    }
}
