import Foundation
import LocalAuthentication

/**
 * iOS LocalAuthentication 对译：Face ID、Touch ID 和可选的设备密码回退。
 *
 * 这是当前 Lynx Module 自有的 Biometrics 能力，不使用摄像头做人脸识别，也不依赖
 * 上游 Capacitor plugin。每个认证请求都保留自己的 LAContext，并按 Module owner
 * 在页面销毁时失效，避免系统回调落到已经释放的 Lynx 页面。
 */
enum LynxNativeBiometricsCapabilities {
    typealias Completion = (LynxNativeCapabilityResult) -> Void

    private static let lock = NSLock()
    private static var pending: [String: PendingAuthentication] = [:]

    private struct PendingAuthentication {
        let ownerID: String?
        let context: LAContext
    }

    static func dispatch(
        _ call: LynxNativeCapabilityCall,
        completion: @escaping Completion
    ) -> Bool {
        guard call.pluginId == "Biometrics" else { return false }
        switch call.methodName {
        case "isAvailable":
            completion(availabilityResult())
        case "getBiometryType":
            completion(.success(biometryData()))
        case "authenticate":
            authenticate(call, completion: completion)
        default:
            completion(.failure("UNSUPPORTED", "Biometrics.\(call.methodName) 尚未接入当前 iOS Module"))
        }
        return true
    }

    static func release(ownerID: String) {
        let contexts = lock.withLock { () -> [LAContext] in
            let matching = pending.filter { $0.value.ownerID == ownerID }
            matching.keys.forEach { pending.removeValue(forKey: $0) }
            return matching.values.map(\.context)
        }
        contexts.forEach { $0.invalidate() }
    }

    static func releaseAll() {
        let contexts = lock.withLock { () -> [LAContext] in
            let values = Array(pending.values).map(\.context)
            pending.removeAll()
            return values
        }
        contexts.forEach { $0.invalidate() }
    }

    private static func availabilityResult() -> LynxNativeCapabilityResult {
        let context = LAContext()
        var error: NSError?
        let available = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &error
        )
        var data = biometryData(context: context)
        data["available"] = available
        data["canEvaluatePolicy"] = available
        data["reason"] = error?.localizedDescription ?? NSNull()
        return .success(data)
    }

    private static func biometryData() -> [String: Any] {
        biometryData(context: LAContext())
    }

    private static func biometryData(context: LAContext) -> [String: Any] {
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        let type = biometryTypeName(context.biometryType)
        return [
            "type": type,
            "biometryType": type,
            "supportsFaceID": type == "FACE_ID",
            "supportsTouchID": type == "TOUCH_ID",
            "supportsOpticID": type == "OPTIC_ID",
        ]
    }

    private static func authenticate(
        _ call: LynxNativeCapabilityCall,
        completion: @escaping Completion
    ) {
        guard faceIDUsageDescriptionPresent() else {
            completion(.failure(
                "PERMISSION_NOT_DECLARED",
                "宿主未声明 NSFaceIDUsageDescription"
            ))
            return
        }

        let allowDeviceCredential = bool(
            call.options["allowDeviceCredential"] ?? call.options["fallbackToPasscode"],
            default: false
        )
        let policy: LAPolicy = allowDeviceCredential
            ? .deviceOwnerAuthentication
            : .deviceOwnerAuthenticationWithBiometrics
        let context = LAContext()
        if let cancelTitle = stringOptional(call.options["cancelTitle"]) {
            context.localizedCancelTitle = cancelTitle
        }
        if !allowDeviceCredential {
            // 空字符串会隐藏系统的“输入密码”回退按钮，保持 Face ID-only 语义。
            context.localizedFallbackTitle = ""
        }

        var evaluationError: NSError?
        guard context.canEvaluatePolicy(policy, error: &evaluationError) else {
            completion(authenticationFailure(
                evaluationError ?? NSError(
                    domain: LAError.errorDomain,
                    code: LAError.biometryNotAvailable.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "当前设备不可用生物识别"]
                ),
                context: context
            ))
            return
        }

        let requestID = UUID().uuidString
        lock.withLock {
            pending[requestID] = PendingAuthentication(ownerID: call.ownerID, context: context)
        }
        let reason = string(
            call.options["reason"] ?? call.options["localizedReason"],
            default: "请验证你的身份"
        )
        context.evaluatePolicy(policy, localizedReason: reason) { success, error in
            let isActive = lock.withLock { pending.removeValue(forKey: requestID) != nil }
            guard isActive else { return }
            DispatchQueue.main.async {
                if success {
                    completion(.success([
                        "authenticated": true,
                        "biometryType": biometryTypeName(context.biometryType),
                        "policy": allowDeviceCredential ? "deviceOwnerAuthentication" : "biometricsOnly",
                    ]))
                } else if let error {
                    completion(authenticationFailure(error as NSError, context: context))
                } else {
                    completion(.failure(
                        "AUTHENTICATION_FAILED",
                        "系统未返回 Face ID 鉴权结果",
                        details: ["biometryType": biometryTypeName(context.biometryType)]
                    ))
                }
            }
        }
    }

    private static func authenticationFailure(
        _ error: NSError,
        context: LAContext
    ) -> LynxNativeCapabilityResult {
        let code: String
        switch error.code {
        case LAError.authenticationFailed.rawValue:
            code = "AUTHENTICATION_FAILED"
        case LAError.userCancel.rawValue:
            code = "USER_CANCELLED"
        case LAError.userFallback.rawValue:
            code = "USER_FALLBACK"
        case LAError.systemCancel.rawValue:
            code = "SYSTEM_CANCELLED"
        case LAError.appCancel.rawValue:
            code = "APP_CANCELLED"
        case LAError.invalidContext.rawValue:
            code = "INVALID_CONTEXT"
        case LAError.biometryNotAvailable.rawValue:
            code = "BIOMETRY_UNAVAILABLE"
        case LAError.biometryNotEnrolled.rawValue:
            code = "BIOMETRY_NOT_ENROLLED"
        case LAError.biometryLockout.rawValue:
            code = "BIOMETRY_LOCKOUT"
        case LAError.passcodeNotSet.rawValue:
            code = "PASSCODE_NOT_SET"
        case LAError.notInteractive.rawValue:
            code = "NOT_INTERACTIVE"
        default:
            code = "AUTHENTICATION_FAILED"
        }
        return .failure(
            code,
            error.localizedDescription,
            details: [
                "nativeDomain": error.domain,
                "nativeCode": error.code,
                "biometryType": biometryTypeName(context.biometryType),
            ]
        )
    }

    private static func biometryTypeName(_ type: LABiometryType) -> String {
        switch type {
        case .faceID: return "FACE_ID"
        case .touchID: return "TOUCH_ID"
        default:
            if #available(iOS 17.0, *), type == .opticID { return "OPTIC_ID" }
            return "NONE"
        }
    }

    private static func faceIDUsageDescriptionPresent() -> Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "NSFaceIDUsageDescription") as? String else {
            return false
        }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func stringOptional(_ value: Any?) -> String? {
        let value = string(value, default: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func string(_ value: Any?, default defaultValue: String) -> String {
        guard let value, !(value is NSNull) else { return defaultValue }
        if let value = value as? String { return value }
        return String(describing: value)
    }

    private static func bool(_ value: Any?, default defaultValue: Bool) -> Bool {
        guard let value, !(value is NSNull) else { return defaultValue }
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return ["true", "1", "yes", "on"].contains(string(value, default: "").lowercased())
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
