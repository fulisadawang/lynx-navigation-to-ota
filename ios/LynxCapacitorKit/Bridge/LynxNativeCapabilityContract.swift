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

        if let rawCallbackId = object["callbackId"], !(rawCallbackId is NSNull) {
            guard let callback = rawCallbackId as? String,
                  !callback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LynxNativeCapabilityError.invalidArgument("callbackId 必须是非空字符串，缺省或 null 才使用 -1")
            }
            callbackId = callback.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            callbackId = "-1"
        }
        guard let plugin = object["pluginId"] as? String, !plugin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let method = object["methodName"] as? String, !method.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LynxNativeCapabilityError.invalidArgument("pluginId 和 methodName 必须是非空字符串")
        }
        pluginId = plugin.trimmingCharacters(in: .whitespacesAndNewlines)
        methodName = method.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawOptions = object["options"], !(rawOptions is NSNull), !(rawOptions is [String: Any]) {
            throw LynxNativeCapabilityError.invalidArgument("options 必须是 JSON 对象")
        }
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
    private var encodedEnvelope: String? = nil

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
        if var error {
            if error["reasonCode"] == nil {
                error["reasonCode"] = LynxCapabilitySemantics.errorReasonCode(for: String(error["code"] as? String ?? ""))
            }
            value["error"] = LynxNativeJSON.normalize(error)
        }
        if let raw = LynxNativeJSON.encode(value) { return raw }
        return LynxNativeJSON.encode([
            "callbackId": call.callbackId, "pluginId": call.pluginId, "methodName": call.methodName,
            "success": false, "save": false,
            "error": ["code": "ENCODING_FAILED", "reasonCode": "NATIVE_ERROR", "message": "原生结果不是合法 JSON"],
        ])!
    }

    func boundedEnvelope(for call: LynxNativeCapabilityCall) -> String {
        if let encodedEnvelope { return encodedEnvelope }
        return preEncoded(for: call).encodedEnvelope!
    }

    /** IO adapter 在线程内完成 JSON，owner 门禁在主线程只交付已编码结果。 */
    func preEncoded(for call: LynxNativeCapabilityCall) -> Self {
        guard LynxNativeJSON.isWithinLimit(data ?? error ?? [:], bytes: LynxNativePayloadLimits.outputJSONBytes) else {
            var failure = Self.failure("PAYLOAD_TOO_LARGE", "原生结果超过内联上限，请使用 URI 或缩小查询范围")
            failure.encodedEnvelope = failure.envelope(for: call)
            return failure
        }
        guard JSONSerialization.isValidJSONObject(LynxNativeJSON.normalize(data ?? error ?? [:])) else {
            var failure = Self.failure("ENCODING_FAILED", "原生结果不是合法 JSON")
            failure.encodedEnvelope = failure.envelope(for: call)
            return failure
        }
        let raw = envelope(for: call)
        guard raw.utf8.count <= LynxNativePayloadLimits.outputJSONBytes else {
            var failure = Self.failure("PAYLOAD_TOO_LARGE", "原生结果超过 JSON 上限")
            failure.encodedEnvelope = failure.envelope(for: call)
            return failure
        }
        var value = self
        value.encodedEnvelope = raw
        return value
    }
}

enum LynxNativeCapabilityError: LocalizedError {
    case invalidPayload
    case invalidArgument(String)
    case payloadTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidPayload: return "Invalid bridge payload"
        case let .invalidArgument(message): return message
        case .payloadTooLarge: return "原生请求超过 JSON 内联上限"
        }
    }

    var code: String {
        switch self {
        case .invalidPayload: return "INVALID_PAYLOAD"
        case .invalidArgument: return "INVALID_ARGUMENT"
        case .payloadTooLarge: return "PAYLOAD_TOO_LARGE"
        }
    }
}

enum LynxNativeJSON {
    static func isWithinLimit(_ value: Any, bytes: Int) -> Bool {
        var remaining = bytes
        func consume(_ value: Any) -> Bool {
            if let text = value as? String { remaining -= text.utf8.count + 2 }
            else if let data = value as? Data { remaining -= ((data.count + 2) / 3) * 4 + 2 }
            else if let values = value as? [String: Any] {
                remaining -= 2
                for (key, value) in values {
                    remaining -= key.utf8.count + 3
                    if remaining < 0 || !consume(value) { return false }
                }
            } else if let values = value as? [Any] {
                remaining -= max(0, values.count - 1) + 2
                for value in values { if remaining < 0 || !consume(value) { return false } }
            } else { remaining -= 1 }
            return remaining >= 0
        }
        return consume(value)
    }
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
