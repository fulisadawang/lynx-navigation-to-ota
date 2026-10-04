import Foundation
import Lynx

/** 宿主组合根安装媒体能力；Shell 不依赖具体能力 Pod。 */
public typealias LynxShellMediaHandler = (LynxContext, String, String, @escaping LynxCallbackBlock) -> Void

/** 只保留旧五方法 ABI 的适配入口，资源与请求归调用页面的能力 owner。 */
final class ShellMediaBridge {
    static let shared = ShellMediaBridge()
    private let lock = NSLock()
    private var handler: LynxShellMediaHandler?

    func install(_ handler: LynxShellMediaHandler?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func handle(context: LynxContext?, method: String, optionsJSON: String, callback: @escaping LynxCallbackBlock) {
        guard let context, !context.hasLynxViewDestroyed else {
            callback(["code": -1, "msg": "页面上下文已销毁"])
            return
        }
        lock.lock()
        let installed = handler
        lock.unlock()
        guard let installed else {
            callback(["code": -1, "msg": "宿主未安装原生媒体能力"])
            return
        }
        installed(context, method, optionsJSON, callback)
    }
}
