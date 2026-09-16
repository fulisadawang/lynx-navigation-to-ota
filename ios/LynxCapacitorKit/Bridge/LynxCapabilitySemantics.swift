import Foundation

/**
 * 三端共用的能力语义字段和错误分类。
 *
 * 该类型只描述公共协议，不替代 iOS 的具体系统能力适配器。
 */
enum LynxCapabilitySemantics {
    static let contractVersion = "1.1"

    static func semanticState(_ state: String) -> String {
        switch state {
        case "native", "partial", "unsupported": return state
        case "implemented": return "native"
        default: return "partial"
        }
    }

    static func reasonCode(for id: String, state: String) -> String {
        if state == "native" || state == "implemented" { return "NONE" }
        switch id {
        case "Biometrics": return "NONE"
        case "Browser": return "EXTERNAL_OWNER"
        case "Keyboard": return "PLATFORM_UNSUPPORTED"
        case "PushNotifications", "BackgroundRunner": return "HOST_PROVIDER_REQUIRED"
        case "Haptics": return "APPROXIMATE_IMPLEMENTATION"
        case "Share": return "SEMANTIC_VARIANT"
        case "Filesystem", "CapacitorCookies": return "SECURITY_SCOPE_RESTRICTED"
        case "ScreenOrientation": return "HOST_INTEGRATION_REQUIRED"
        case "InAppBrowser", "FileViewer", "SplashScreen": return "RUNTIME_CONTEXT_REQUIRED"
        case "Camera", "Geolocation", "Motion", "ScreenReader", "Calendar", "LocalNotifications", "CapacitorBarcodeScanner": return "DEVICE_FEATURE_REQUIRED"
        case "FileTransfer", "CapacitorHttp": return "SEMANTIC_VARIANT"
        case "TextZoom": return "METHOD_GAP"
        case "PrivacyScreen": return "APPROXIMATE_IMPLEMENTATION"
        default: return "RUNTIME_VERIFICATION_REQUIRED"
        }
    }

    static func reason(for id: String, state: String) -> String {
        switch reasonCode(for: id, state: state) {
        case "NONE": return "公共最小语义在源码中已实现。"
        case "METHOD_GAP": return "能力目录中仍有方法没有实现。"
        case "PLATFORM_UNSUPPORTED": return "当前平台没有可安全承诺的等价实现。"
        case "SEMANTIC_VARIANT": return "方法存在，但作用范围、结果或完成时机存在平台差异。"
        case "APPROXIMATE_IMPLEMENTATION": return "使用平台近似机制，不能承诺硬件或系统行为完全等价。"
        case "EXTERNAL_OWNER": return "动作由外部系统或第三方应用管理，宿主无法控制完整生命周期。"
        case "HOST_INTEGRATION_REQUIRED": return "需要宿主注册、窗口协议或生命周期转发。"
        case "HOST_PROVIDER_REQUIRED": return "需要宿主配置或厂商服务 Provider。"
        case "RUNTIME_CONTEXT_REQUIRED": return "需要有效页面、窗口或前台上下文。"
        case "DEVICE_FEATURE_REQUIRED": return "需要系统权限、设备硬件或系统服务，并且还需要运行验收。"
        case "SECURITY_SCOPE_RESTRICTED": return "目录、URI、Cookie 或其他安全边界限制了公共语义。"
        default: return "源码分支存在，但还没有完整运行证据。"
        }
    }

    static func methodReasonCode(for id: String, method: String, implemented: Bool) -> String {
        if implemented { return "NONE" }
        if id == "Browser" && method == "close" { return "EXTERNAL_OWNER" }
        if id == "Keyboard" && method == "setStyle" { return "PLATFORM_UNSUPPORTED" }
        if id == "PushNotifications" && method == "register" { return "HOST_PROVIDER_REQUIRED" }
        if id == "BackgroundRunner" && method == "dispatchEvent" { return "HOST_PROVIDER_REQUIRED" }
        if id == "Biometrics" { return "PLATFORM_UNSUPPORTED" }
        if id == "TextZoom" && method == "set" { return "METHOD_GAP" }
        if id == "LocalNotifications" && ["createChannel", "listChannels"].contains(method) { return "PLATFORM_UNSUPPORTED" }
        return "METHOD_GAP"
    }

    static func methodStatus(id: String, methods: [String], implementedMethods: [String]) -> [[String: Any]] {
        methods.map { method in
            let implemented = implementedMethods.contains(method)
            return [
                "name": method,
                "state": implemented ? "native" : "unsupported",
                "reasonCode": methodReasonCode(for: id, method: method, implemented: implemented),
            ]
        }
    }

    static func verification() -> [String: Any] {
        [
            "source": "verified",
            "build": "not_run",
            "host": "not_integrated",
            "device": "not_run",
        ]
    }

    static func errorReasonCode(for code: String) -> String {
        switch code {
        case "INVALID_PAYLOAD": return "INVALID_PAYLOAD"
        case "INVALID_ARGUMENT": return "INVALID_ARGUMENT"
        case "UNIMPLEMENTED": return "METHOD_GAP"
        case "UNSUPPORTED": return "PLATFORM_UNSUPPORTED"
        case "PERMISSION_NOT_DECLARED": return "HOST_PERMISSION_CONFIGURATION_REQUIRED"
        case "PERMISSION_DENIED": return "RUNTIME_PERMISSION_DENIED"
        case "MODULE_UNAVAILABLE", "SCENE_UNAVAILABLE", "HOST_UNAVAILABLE": return "RUNTIME_CONTEXT_REQUIRED"
        case "CANCELLED": return "CANCELLED"
        case "ACTIVITY_DESTROYED", "HOST_DESTROYED": return "HOST_DESTROYED"
        default: return "NATIVE_ERROR"
        }
    }
}
