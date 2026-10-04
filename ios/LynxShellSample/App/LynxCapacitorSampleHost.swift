#if LYNX_SHELL_E2E_CORE_ONLY
import LynxShellKitE2ECore
#else
import LynxShellKit
#endif
import UIKit
import Lynx
import LynxCapacitorKit

/** App composition root 连接两个独立 Pod；注册表只描述确实提供的 Host 方法。 */
final class LynxCapacitorSampleHost: LynxCapacitorHostProvider {
    let supportedMethods: [String: [String]] = [
        "StatusBar": ["getInfo", "setStyle", "hide", "show"],
        "SystemBars": ["setStyle"],
        "SafeArea": ["setSystemBarsStyle", "hideSystemBars", "showSystemBars"],
        "ScreenOrientation": ["orientation", "lock", "unlock"],
        "Keyboard": ["setStyle"],
    ]
    private let hosts = NSMapTable<LynxContext, SystemUIAdapter>.weakToStrongObjects()

    func host(for context: LynxContext) -> AnyObject? {
        precondition(Thread.isMainThread)
        if let existing = hosts.object(forKey: context) { return existing.handle.isAvailable ? existing : nil }
        guard let view = context.getLynxView(), let handle = LynxRouter.systemUIHandle(for: view) else { return nil }
        guard handle.isAvailable else { return nil }
        let adapter = SystemUIAdapter(handle: handle)
        hosts.setObject(adapter, forKey: context)
        return adapter
    }

    func releaseHost(for context: LynxContext) {
        precondition(Thread.isMainThread)
        hosts.object(forKey: context)?.handle.restore()
        hosts.removeObject(forKey: context)
    }
}

private final class SystemUIAdapter: LynxCapacitorStatusBarHost, LynxCapacitorSystemBarsHost,
    LynxCapacitorOrientationHost, LynxCapacitorKeyboardHost {
    let handle: LynxSystemUIHandle
    init(handle: LynxSystemUIHandle) { self.handle = handle }
    func capacitorStatusBarInfo() -> [String: Any] { handle.statusBarInfo }
    func setCapacitorStatusBarVisible(_ visible: Bool) { _ = handle.setStatusBarVisible(visible) }
    func setCapacitorStatusBarStyle(_ value: String) -> Bool { handle.setSystemBarsStyle(value) }
    func setCapacitorStatusBarColor(_ value: String) -> Bool { false }
    func setCapacitorStatusBarOverlay(_ overlay: Bool) { }
    func setCapacitorSystemBarsStyle(_ value: String) -> Bool { handle.setSystemBarsStyle(value) }
    func setCapacitorSystemBarsVisible(_ visible: Bool) { _ = handle.setSystemBarsVisible(visible) }
    func setCapacitorSafeAreaVisible(_ visible: Bool, type: String) -> Bool { handle.setSystemBarsVisible(visible, type: type) }
    func applyCapacitorOrientation(_ value: String, completion: @escaping (Result<[String: Any], Error>) -> Void) { handle.setOrientation(value, completion: completion) }
    func clearCapacitorOrientation(completion: @escaping (Result<[String: Any], Error>) -> Void) { handle.clearOrientation(completion: completion) }
    func setCapacitorKeyboardStyle(_ value: String) -> Bool { handle.setKeyboardStyle(value) }
    func showCapacitorKeyboard() -> Bool { false }
    func setCapacitorKeyboardAccessoryBarVisible(_ visible: Bool) -> Bool { false }
}
