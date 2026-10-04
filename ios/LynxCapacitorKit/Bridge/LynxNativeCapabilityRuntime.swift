import Foundation
import Lynx
import UIKit

/**
 * iOS 自研能力 Runtime。
 *
 * 该类只处理 Lynx JSON transport、UIViewController 生命周期和结果封装；
 * 原生行为全部进入 `LynxNativeCapabilityDispatcher`。这里没有 Capacitor Bridge、
 * plugin class、reflection 或第三方 runtime。
 */
final class LynxNativeCapabilityRuntime: NSObject {
    private static let launchURLLock = NSLock()
    private static var latestLaunchURL: String?
    private weak var lynxContext: LynxContext?
    private let dispatcher: LynxNativeCapabilityDispatcher
    private let scope = LynxNativeOwnerScope()
    private var ownerID: String { scope.id }
    private let testDispatch: ((LynxNativeCapabilityCall, @escaping (LynxNativeCapabilityResult) -> Void) -> Void)?
    var isActive: Bool { scope.isActive }

    init(lynxContext: LynxContext? = nil, deferContextValidation: Bool = false,
         dispatch: ((LynxNativeCapabilityCall, @escaping (LynxNativeCapabilityResult) -> Void) -> Void)? = nil) {
        self.lynxContext = lynxContext
        testDispatch = dispatch
        dispatcher = LynxNativeCapabilityDispatcher()
        super.init()
        if !deferContextValidation, lynxContext?.hasLynxViewDestroyed == true { release() }
    }

    deinit { release() }

    func setContext(_ context: LynxContext?) {
        lynxContext = context
    }

    func getPlatform() -> String { "ios" }

    func getPluginHeaders() -> String {
        LynxNativeCapabilityCatalog.headersJSON()
    }

    func getCapabilityStatus() -> String {
        LynxNativeCapabilityCatalog.statusJSON(platform: "ios", hostMethods: LynxCapacitorHostRegistry.supportedMethods())
    }

    func setEventSender(_ sender: ((String) -> Void)?) {
        dispatcher.setEventSender { [weak scope] raw in
            guard scope?.isActive == true else { return }
            sender?(raw)
        }
    }

    func handleCall(_ payload: String, callback: @escaping (String) -> Void) {
        handleCall(payload, transportCallback: { raw, _ in callback(raw) })
    }

    /** 旧 ABI 的独立输入预算避免 20 MiB Data URL 被普通 transport 的 1 MiB 闸门截断。 */
    func handleLegacyMedia(method: String, optionsJSON: String, callback: @escaping LynxCallbackBlock) {
        if lynxContext?.hasLynxViewDestroyed == true { release() }
        let large = method == "saveDataURL" && optionsJSON.utf8.count > LynxNativePayloadLimits.inputJSONBytes
        guard !large || LynxNativeLegacyMediaInput.admitLargeInput() else {
            let receipt = LynxNativeLegacyMediaCapabilities.receipt(for: .failure("BUSY", "已有大 Data URL 正在处理"))
            if Thread.isMainThread { callback(receipt) } else { DispatchQueue.main.async { callback(receipt) } }
            return
        }
        let input = LynxNativeLegacyMediaInput(optionsJSON, ownerID: ownerID, large: large)
        let identity = LynxNativeCapabilityCall(callbackId: "-1", pluginId: "LegacyMedia", methodName: method, options: [:])
        guard let token = scope.begin({ result in
            input.finish()
            let receipt = LynxNativeLegacyMediaCapabilities.receipt(for: result)
            if Thread.isMainThread { callback(receipt) } else { DispatchQueue.main.async { callback(receipt) } }
        }) else { return }
        let finish: (LynxNativeCapabilityResult) -> Void = { [scope] result in
            scope.complete(token, result.preEncoded(for: identity))
        }
        LynxNativeIOExecutor.shared.submit(ownerID: ownerID, completion: { [weak self, scope] parsed in
            if method == "saveDataURL" { finish(parsed); return }
            guard parsed.success, let options = parsed.data?["options"] as? [String: Any] else { finish(parsed); return }
            if method != "chooseMedia" {
                guard let self, scope.isActive else { return }
                if self.lynxContext?.hasLynxViewDestroyed == true { self.release(); return }
                LynxNativeLegacyMediaCapabilities.dispatch(method: method, options: options, ownerID: self.ownerID,
                                                           presenter: nil, completion: finish)
                return
            }
            guard input.store(options: options) else { return }
            DispatchQueue.main.async {
                guard let self, scope.isActive, let options = input.takeOptions() else { return }
                if self.lynxContext?.hasLynxViewDestroyed == true { self.release(); return }
                LynxNativeLegacyMediaCapabilities.dispatch(method: method, options: options, ownerID: self.ownerID,
                    presenter: LynxNativeCapabilitySupport.presenter(for: self.lynxContext), completion: finish)
            }
        }) { [ownerID] cancellation in
            guard let json = input.take() else { return .failure("HOST_DESTROYED", "媒体输入已取消") }
            let parsed = LynxNativeLegacyMediaCapabilities.parse(method: method, optionsJSON: json)
            if method == "saveDataURL", parsed.success, let options = parsed.data?["options"] as? [String: Any] {
                return LynxNativeLegacyMediaCapabilities.saveDataURL(options, ownerID: ownerID, cancellation: cancellation)
            }
            return parsed
        }
    }

    func handleCall(_ payload: String, transportCallback: @escaping (String, Bool) -> Void) {
        if lynxContext?.hasLynxViewDestroyed == true { release() }
        guard scope.isActive else {
            let identity = payload.utf8.count <= LynxNativePayloadLimits.inputJSONBytes ? Self.identity(from: payload) : (callbackID: "-1", pluginID: "", methodName: "")
            let raw = Self.errorEnvelope(callbackId: identity.callbackID, pluginId: identity.pluginID, methodName: identity.methodName,
                                         code: "HOST_DESTROYED", message: "页面上下文已销毁")
            if Thread.isMainThread { transportCallback(raw, false) } else { DispatchQueue.main.async { transportCallback(raw, false) } }
            return
        }
        let parsedCall: LynxNativeCapabilityCall
        do {
            guard payload.utf8.count <= LynxNativePayloadLimits.inputJSONBytes else {
                throw LynxNativeCapabilityError.payloadTooLarge
            }
            parsedCall = try LynxNativeCapabilityCall(payload: payload)
        } catch {
            let capabilityError = error as? LynxNativeCapabilityError
            let identity = payload.utf8.count > LynxNativePayloadLimits.inputJSONBytes ? (callbackID: "-1", pluginID: "", methodName: "") : Self.identity(from: payload)
            let envelope = Self.errorEnvelope(
                callbackId: identity.callbackID,
                pluginId: identity.pluginID,
                methodName: identity.methodName,
                code: capabilityError?.code ?? "INVALID_PAYLOAD",
                message: error.localizedDescription
            )
            if Thread.isMainThread { transportCallback(envelope, false) } else { DispatchQueue.main.async { transportCallback(envelope, false) } }
            return
        }

        let call = parsedCall.withOwner(ownerID)
        guard let token = scope.begin({ result in
            let envelope = result.boundedEnvelope(for: call)
            if Thread.isMainThread { transportCallback(envelope, result.save) } else { DispatchQueue.main.async { transportCallback(envelope, result.save) } }
        }) else { return }
        let run = { [weak self, scope] in
            guard let self, scope.isActive else { return }
            let finish: (LynxNativeCapabilityResult) -> Void = { result in
                guard scope.isActive else { return }
                scope.complete(token, result.preEncoded(for: call))
            }
            if let testDispatch = self.testDispatch { testDispatch(call, finish); return }
            let presenter = LynxNativeCapabilitySupport.presenter(for: self.lynxContext)
            let host = self.lynxContext.flatMap { LynxCapacitorHostRegistry.current()?.host(for: $0) }
            self.dispatcher.dispatch(call, presenter: presenter, host: host, completion: finish)
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
    }

    func setLaunchURL(_ url: String?) { Self.publishLaunchURL(url) }
    func getLaunchURL() -> String? { Self.globalLaunchURL() }

    static func publishLaunchURL(_ url: String?) {
        launchURLLock.lock()
        latestLaunchURL = url
        launchURLLock.unlock()
    }

    static func globalLaunchURL() -> String? {
        launchURLLock.lock()
        defer { launchURLLock.unlock() }
        return latestLaunchURL
    }

    func emitAppURL(_ url: String) {
        dispatcher.sendEvent([
            "pluginId": "App",
            "methodName": "appUrlOpen",
            "eventName": "appUrlOpen",
            "success": true,
            "data": ["url": url],
            "save": true,
        ])
    }

    func emitPushRegistration(token: String) {
        dispatcher.sendEvent([
            "pluginId": "PushNotifications",
            "methodName": "registration",
            "eventName": "registration",
            "success": true,
            "data": ["value": token],
            "save": true,
        ])
    }

    func emitPushRegistrationError(_ message: String) {
        dispatcher.sendEvent([
            "pluginId": "PushNotifications",
            "methodName": "registrationError",
            "eventName": "registrationError",
            "success": false,
            "error": [
                "code": "PUSH_REGISTRATION_FAILED",
                "reasonCode": LynxCapabilitySemantics.errorReasonCode(for: "PUSH_REGISTRATION_FAILED"),
                "message": message,
            ],
            "save": true,
        ])
    }

    func emitPushNotification(_ userInfo: [AnyHashable: Any]) {
        dispatcher.sendEvent([
            "pluginId": "PushNotifications",
            "methodName": "pushNotificationReceived",
            "eventName": "pushNotificationReceived",
            "success": true,
            "data": LynxNativeJSON.normalize(userInfo),
            "save": true,
        ])
    }

    func release() {
        guard scope.close() else { return }
        dispatcher.setEventSender(nil)
        LynxNativeIOExecutor.shared.cancel(ownerID: ownerID)
        LynxNativeIOExecutor.network.cancel(ownerID: ownerID)
        let context = lynxContext
        lynxContext = nil
        let clean = { [ownerID] in
            LynxNativeProviderCapabilities.release(ownerID: ownerID)
            LynxNativeMediaCapabilities.release(ownerID: ownerID)
            LynxNativeBarcodeCapabilities.release(ownerID: ownerID)
            LynxNativeAudioCapabilities.release(ownerID: ownerID)
            LynxNativeBiometricsCapabilities.release(ownerID: ownerID)
            LynxNativeInteractiveCapabilities.release(ownerID: ownerID)
            LynxNativeSystemCapabilities.release(ownerID: ownerID)
            if let context { LynxCapacitorHostRegistry.current()?.releaseHost(for: context) }
        }
        // SQLite 连接按数据库归属，页面销毁不关闭其他业务共享连接。
        if Thread.isMainThread { clean() } else { DispatchQueue.main.async(execute: clean) }
    }

    private static func errorEnvelope(
        callbackId: String,
        pluginId: String,
        methodName: String,
        code: String,
        message: String
    ) -> String {
        LynxNativeCapabilityResult
            .failure(code, message)
            .envelope(for: LynxNativeCapabilityCall(
                callbackId: callbackId,
                pluginId: pluginId,
                methodName: methodName,
                options: [:]
            ))
    }

    /** 解析失败时尽量保留调用方的身份字段，便于页面归并错误。 */
    private static func identity(from payload: String) -> (callbackID: String, pluginID: String, methodName: String) {
        guard
            let data = payload.data(using: .utf8),
            let raw = try? JSONSerialization.jsonObject(with: data),
            let object = raw as? [String: Any]
        else { return ("-1", "", "") }
        let callbackValue = (object["callbackId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let callbackID = callbackValue.isEmpty ? "-1" : callbackValue
        let pluginID = (object["pluginId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let methodName = (object["methodName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (callbackID, pluginID, methodName)
    }
}
