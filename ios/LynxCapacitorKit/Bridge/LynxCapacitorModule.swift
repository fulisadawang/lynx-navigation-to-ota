import Foundation
import Lynx
import UIKit

/** LynxShell 原有容器协议，保留类型边界但不参与 Capacitor plugin dispatch。 */
public protocol LynxCapacitorOrientationHost: AnyObject {
    func applyCapacitorOrientation(_ value: String, completion: @escaping (Result<[String: Any], Error>) -> Void)
    func clearCapacitorOrientation(completion: @escaping (Result<[String: Any], Error>) -> Void)
}

public protocol LynxCapacitorStatusBarHost: AnyObject {
    func setCapacitorStatusBarVisible(_ visible: Bool)
    func setCapacitorStatusBarStyle(_ value: String) -> Bool
    func setCapacitorStatusBarColor(_ value: String) -> Bool
    func setCapacitorStatusBarOverlay(_ overlay: Bool)
    func capacitorStatusBarInfo() -> [String: Any]
}

public protocol LynxCapacitorSystemBarsHost: AnyObject {
    func setCapacitorSystemBarsStyle(_ value: String) -> Bool
    func setCapacitorSystemBarsVisible(_ visible: Bool)
    func setCapacitorSafeAreaVisible(_ visible: Bool, type: String) -> Bool
}

public protocol LynxCapacitorKeyboardHost: AnyObject {
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
    private static let moduleLock = NSLock()
    private static let runtimeLock = NSLock()
    private static let runtimes = NSMapTable<LynxContext, LynxNativeCapabilityRuntime>(
        keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)
    private weak var lynxContext: LynxContext?
    private let runtime: LynxNativeCapabilityRuntime

    public static var name: String { "LynxCapacitorModule" }

    @nonobjc public static func installHostProvider(_ provider: LynxCapacitorHostProvider?) {
        LynxCapacitorHostRegistry.install(provider)
    }

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
        runtime = Self.runtime(for: lynxContext)
        super.init()
        Self.register(self)
        runtime.setEventSender { [weak self] raw in self?.deliverEvent(raw) }
    }

    public required init(lynxContext: LynxContext, withParam param: Any) {
        self.lynxContext = lynxContext
        runtime = Self.runtime(for: lynxContext)
        super.init()
        Self.register(self)
        runtime.setEventSender { [weak self] raw in self?.deliverEvent(raw) }
        _ = param
    }

    public init(param: Any) {
        runtime = LynxNativeCapabilityRuntime()
        super.init()
        Self.register(self)
        runtime.setEventSender { [weak self] raw in self?.deliverEvent(raw) }
        _ = param
    }

    public override init() {
        runtime = LynxNativeCapabilityRuntime()
        super.init()
        Self.register(self)
        runtime.setEventSender { [weak self] raw in self?.deliverEvent(raw) }
    }

    public func destroy() {
        Self.moduleLock.lock()
        Self.moduleTable.remove(self)
        Self.moduleLock.unlock()
        if let context = lynxContext { Self.removeRuntime(for: context, matching: runtime) }
        else { runtime.release() }
        lynxContext = nil
    }

    /** 由宿主统一 View 销毁出口调用；SDK 声明 destroy 不代表当前实现会自动执行。 */
    @nonobjc public static func destroy(for context: LynxContext) {
        removeRuntime(for: context)
        modulesSnapshot().filter { $0.lynxContext === context }.forEach { $0.destroy() }
    }

    /** 不新增 JS transport；Shell 的旧媒体入口与惰性创建的 Module 共享同一上下文。 */
    @nonobjc public static func handleLegacyMedia(for context: LynxContext, method: String,
                                                optionsJSON: String, callback: @escaping LynxCallbackBlock) {
        runtime(for: context).handleLegacyMedia(method: method, optionsJSON: optionsJSON, callback: callback)
    }

    @nonobjc private static func runtime(for context: LynxContext) -> LynxNativeCapabilityRuntime {
        runtimeLock.lock()
        let runtime: LynxNativeCapabilityRuntime
        if let existing = runtimes.object(forKey: context) { runtime = existing }
        else {
            runtime = LynxNativeCapabilityRuntime(lynxContext: context, deferContextValidation: true)
            runtimes.setObject(runtime, forKey: context)
        }
        runtimeLock.unlock()
        if context.hasLynxViewDestroyed { removeRuntime(for: context, matching: runtime) }
        return runtime
    }

    /** 只在锁内解绑；取消网络、回调和 UIKit 清理不能持 registry 锁。 */
    @nonobjc private static func removeRuntime(for context: LynxContext, matching expected: LynxNativeCapabilityRuntime? = nil) {
        runtimeLock.lock()
        let registered = runtimes.object(forKey: context)
        let runtime = expected ?? registered
        if let registered, expected == nil || registered === expected { runtimes.removeObject(forKey: context) }
        runtimeLock.unlock()
        runtime?.release()
    }

    public func getPluginHeaders() -> String { runtime.getPluginHeaders() }
    public func getPlatform() -> String { runtime.getPlatform() }

    /** 诊断面反映当前工程自有 catalog，不把存在按钮或协议声明伪造成系统能力。 */
    public func getCapabilityStatus() -> String {
        runtime.getCapabilityStatus()
    }

    @objc(handleCall:callback:)
    public func handleCall(_ payload: String, callback: @escaping LynxCallbackBlock) {
        runtime.handleCall(payload, transportCallback: { [weak self] raw, save in
            if save { self?.deliverEvent(raw) }
            else { callback(raw) }
        })
    }

    /** 宿主 URL 生命周期入口进入当前自研 Module 的 App 事件通道。 */
    public static func emitAppUrlOpen(_ url: String) {
        guard !url.isEmpty else { return }
        Self.modulesSnapshot().forEach { $0.runtime.emitAppURL(url) }
    }

    public static func setLaunchUrl(_ url: String?) {
        LynxNativeCapabilityRuntime.publishLaunchURL(url)
    }

    /** 保持既有 Sample AppDelegate 的入口；APNs 结果由自研 Module 事件通道发送。 */
    public static func emitPushRegistration(token: String) {
        Self.modulesSnapshot().forEach { $0.runtime.emitPushRegistration(token: token) }
    }

    public static func emitPushRegistrationError(_ message: String) {
        Self.modulesSnapshot().forEach { $0.runtime.emitPushRegistrationError(message) }
    }

    public static func emitPushNotification(_ userInfo: [AnyHashable: Any]) {
        Self.modulesSnapshot().forEach { module in
            module.runtime.emitPushNotification(userInfo)
        }
    }

    private static func register(_ module: LynxCapacitorModule) {
        moduleLock.lock()
        moduleTable.add(module)
        moduleLock.unlock()
        if module.lynxContext?.hasLynxViewDestroyed == true { module.destroy() }
    }

    private static func modulesSnapshot() -> [LynxCapacitorModule] {
        moduleLock.lock()
        defer { moduleLock.unlock() }
        return moduleTable.allObjects
    }

    private func deliverEvent(_ raw: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.runtime.isActive, let view = self.lynxContext?.getLynxView() else { return }
            view.sendGlobalEvent("lynx-capacitor-result", withParams: [raw])
        }
    }
}
