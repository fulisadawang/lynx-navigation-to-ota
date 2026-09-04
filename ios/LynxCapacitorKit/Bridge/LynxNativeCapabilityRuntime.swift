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
    private static let instanceLock = NSLock()
    private static var activeInstanceCount = 0
    private static let launchURLLock = NSLock()
    private static var latestLaunchURL: String?
    private weak var lynxContext: LynxContext?
    private let dispatcher: LynxNativeCapabilityDispatcher
    private let ownerID = UUID().uuidString
    private var launchURL: String?
    private var released = false

    init(lynxContext: LynxContext? = nil) {
        self.lynxContext = lynxContext
        dispatcher = LynxNativeCapabilityDispatcher()
        super.init()
        Self.instanceLock.withLock { Self.activeInstanceCount += 1 }
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
        LynxNativeCapabilityCatalog.statusJSON(platform: "ios")
    }

    func setEventSender(_ sender: ((String) -> Void)?) {
        dispatcher.setEventSender(sender)
    }

    func handleCall(_ payload: String, callback: @escaping (String) -> Void) {
        let parsedCall: LynxNativeCapabilityCall
        do {
            parsedCall = try LynxNativeCapabilityCall(payload: payload)
        } catch {
            let envelope = Self.errorEnvelope(
                callbackId: "-1",
                pluginId: "",
                methodName: "",
                code: "INVALID_PAYLOAD",
                message: error.localizedDescription
            )
            DispatchQueue.main.async { callback(envelope) }
            return
        }

        let call = parsedCall.withOwner(ownerID)
        let presenter = LynxNativeCapabilitySupport.presenter(for: lynxContext)
        dispatcher.dispatch(call, presenter: presenter) { [weak self] result in
            guard let self, !self.released else { return }
            let envelope = result.envelope(for: call)
            DispatchQueue.main.async {
                callback(envelope)
            }
        }
    }

    func setLaunchURL(_ url: String?) {
        launchURL = url
        Self.launchURLLock.lock()
        Self.latestLaunchURL = url
        Self.launchURLLock.unlock()
    }

    func getLaunchURL() -> String? {
        if let launchURL { return launchURL }
        Self.launchURLLock.lock()
        defer { Self.launchURLLock.unlock() }
        return Self.latestLaunchURL
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
            "success": true,
            "data": ["url": url],
            "save": true,
        ])
    }

    func emitPushRegistration(token: String) {
        dispatcher.sendEvent([
            "pluginId": "PushNotifications",
            "methodName": "registration",
            "success": true,
            "data": ["value": token],
            "save": true,
        ])
    }

    func emitPushRegistrationError(_ message: String) {
        dispatcher.sendEvent([
            "pluginId": "PushNotifications",
            "methodName": "registrationError",
            "success": false,
            "error": ["code": "PUSH_REGISTRATION_FAILED", "message": message],
            "save": true,
        ])
    }

    func emitPushNotification(_ userInfo: [AnyHashable: Any]) {
        dispatcher.sendEvent([
            "pluginId": "PushNotifications",
            "methodName": "pushNotificationReceived",
            "success": true,
            "data": LynxNativeJSON.normalize(userInfo),
            "save": true,
        ])
    }

    func release() {
        guard !released else { return }
        released = true
        dispatcher.setEventSender(nil)
        LynxNativeProviderCapabilities.release(ownerID: ownerID)
        LynxNativeMediaCapabilities.release(ownerID: ownerID)
        LynxNativeBarcodeCapabilities.release(ownerID: ownerID)
        LynxNativeAudioCapabilities.release(ownerID: ownerID)
        LynxNativeBiometricsCapabilities.release(ownerID: ownerID)
        let shouldReleaseSharedAdapters = Self.instanceLock.withLock { () -> Bool in
            Self.activeInstanceCount = max(0, Self.activeInstanceCount - 1)
            return Self.activeInstanceCount == 0
        }
        guard shouldReleaseSharedAdapters else {
            lynxContext = nil
            return
        }
        LynxNativeProviderCapabilities.releaseAll()
        LynxNativeMediaCapabilities.releaseAll()
        LynxNativeBarcodeCapabilities.releaseAll()
        LynxNativeAudioCapabilities.releaseAll()
        LynxNativeBiometricsCapabilities.releaseAll()
        LynxNativeInteractiveCapabilities.release()
        LynxNativeSystemCapabilities.release()
        LynxNativeDatabaseCapabilities.release()
        lynxContext = nil
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
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
