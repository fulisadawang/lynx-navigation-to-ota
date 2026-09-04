import Foundation
import Lynx
import UIKit

/** LynxShell 原有容器协议，保留类型边界但不参与 Capacitor plugin dispatch。 */
protocol LynxCapacitorOrientationHost: AnyObject {
    func applyCapacitorOrientation(_ value: String) -> Bool
    func clearCapacitorOrientation()
}

protocol LynxCapacitorStatusBarHost: AnyObject {
    func setCapacitorStatusBarVisible(_ visible: Bool)
    func setCapacitorStatusBarStyle(_ value: String) -> Bool
    func setCapacitorStatusBarColor(_ value: String) -> Bool
    func setCapacitorStatusBarOverlay(_ overlay: Bool)
    func capacitorStatusBarInfo() -> [String: Any]
}

protocol LynxCapacitorSystemBarsHost: AnyObject {
    func setCapacitorSystemBarsStyle(_ value: String) -> Bool
    func setCapacitorSystemBarsVisible(_ visible: Bool)
    func setCapacitorSafeAreaVisible(_ visible: Bool, type: String) -> Bool
}

protocol LynxCapacitorKeyboardHost: AnyObject {
    func showCapacitorKeyboard() -> Bool
    func setCapacitorKeyboardStyle(_ value: String) -> Bool
    func setCapacitorKeyboardAccessoryBarVisible(_ visible: Bool) -> Bool
}

/**
 * 唯一显式注册的 Lynx NativeModule transport wrapper。
 * 具体原生能力由本工程的 `LynxNativeCapabilityRuntime` 负责；本层只在 Lynx
 * callback 与 GlobalEventEmitter 间转发。`LynxCapacitorModule` 这个名称仅为保持
 * 当前页面协议兼容，不表示链接了上游 Capacitor。
 */
@objc(LynxCapacitorModule)
@objcMembers
public final class LynxCapacitorModule: NSObject, LynxContextModule {
    private static let moduleTable = NSHashTable<LynxCapacitorModule>.weakObjects()
    private weak var lynxContext: LynxContext?
    private let runtime: LynxNativeCapabilityRuntime
    private static var initialLaunchURL: String?

    public static var name: String { "LynxCapacitorModule" }

    public static var methodLookup: [String: String] {
        [
            "handleCall": NSStringFromSelector(#selector(handleCall(_:callback:))),
            "getPluginHeaders": NSStringFromSelector(#selector(getPluginHeaders)),
            "getPlatform": NSStringFromSelector(#selector(getPlatform)),
            "getCapabilityStatus": NSStringFromSelector(#selector(getCapabilityStatus)),
        ]
    }

    public required init(lynxContext: LynxContext) {
        self.lynxContext = lynxContext
        runtime = LynxNativeCapabilityRuntime(lynxContext: lynxContext)
        super.init()
        Self.moduleTable.add(self)
        runtime.setLaunchURL(Self.initialLaunchURL)
        runtime.setEventSender { [weak self] raw in self?.deliverEvent(raw) }
    }

    public required init(lynxContext: LynxContext, withParam param: Any) {
        self.lynxContext = lynxContext
        runtime = LynxNativeCapabilityRuntime(lynxContext: lynxContext)
        super.init()
        Self.moduleTable.add(self)
        runtime.setLaunchURL(Self.initialLaunchURL)
        runtime.setEventSender { [weak self] raw in self?.deliverEvent(raw) }
        _ = param
    }

    public init(param: Any) {
        runtime = LynxNativeCapabilityRuntime()
        super.init()
        Self.moduleTable.add(self)
        runtime.setLaunchURL(Self.initialLaunchURL)
        runtime.setEventSender { [weak self] raw in self?.deliverEvent(raw) }
        _ = param
    }

    public override init() {
        runtime = LynxNativeCapabilityRuntime()
        super.init()
        Self.moduleTable.add(self)
        runtime.setLaunchURL(Self.initialLaunchURL)
        runtime.setEventSender { [weak self] raw in self?.deliverEvent(raw) }
    }

    public func destroy() {
        Self.moduleTable.remove(self)
        runtime.release()
        lynxContext = nil
    }

    public func getPluginHeaders() -> String { runtime.getPluginHeaders() }
    public func getPlatform() -> String { runtime.getPlatform() }

    /** 诊断面反映当前工程自有 catalog，不把存在按钮或协议声明伪造成系统能力。 */
    public func getCapabilityStatus() -> String {
        runtime.getCapabilityStatus()
    }

    @objc(handleCall:callback:)
    public func handleCall(_ payload: String, callback: @escaping LynxCallbackBlock) {
        runtime.handleCall(payload) { [weak self] result in
            guard let raw = result as? String else {
                callback("{}")
                return
            }
            self?.deliver(raw, callback: callback)
        }
    }

    /** 宿主 URL 生命周期入口进入当前自研 Module 的 App 事件通道。 */
    public static func emitAppUrlOpen(_ url: String) {
        guard !url.isEmpty else { return }
        Self.moduleTable.allObjects.forEach { $0.runtime.emitAppURL(url) }
    }

    public static func setLaunchUrl(_ url: String?) {
        initialLaunchURL = url
        Self.moduleTable.allObjects.forEach { $0.runtime.setLaunchURL(url) }
    }

    /** 保持既有 Sample AppDelegate 的入口；APNs 结果由自研 Module 事件通道发送。 */
    public static func emitPushRegistration(token: String) {
        Self.moduleTable.allObjects.forEach { $0.runtime.emitPushRegistration(token: token) }
    }

    public static func emitPushRegistrationError(_ message: String) {
        Self.moduleTable.allObjects.forEach { $0.runtime.emitPushRegistrationError(message) }
    }

    public static func emitPushNotification(_ userInfo: [AnyHashable: Any]) {
        Self.moduleTable.allObjects.forEach { module in
            module.runtime.emitPushNotification(userInfo)
        }
    }

    private func deliverEvent(_ raw: String) {
        guard let view = lynxContext?.getLynxView() else { return }
        DispatchQueue.main.async {
            view.sendGlobalEvent("lynx-capacitor-result", withParams: [raw])
        }
    }

    private func deliver(_ raw: String, callback: @escaping LynxCallbackBlock) {
        let saved = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
        if saved?["save"] as? Bool == true, let view = lynxContext?.getLynxView() {
            DispatchQueue.main.async {
                view.sendGlobalEvent("lynx-capacitor-result", withParams: [raw])
            }
            return
        }
        DispatchQueue.main.async { callback(raw) }
    }
}
