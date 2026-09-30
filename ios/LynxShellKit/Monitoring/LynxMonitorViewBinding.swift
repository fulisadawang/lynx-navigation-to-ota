import Foundation
import Lynx
import ObjectiveC

/** View 持有 Scope，Scope 不持有 View；绑定和查询都在 UIKit 主线程执行。 */
enum LynxMonitorViewBinding {
    private static var scopeKey: UInt8 = 0

    static func bind(_ scope: LynxMonitorScope, to view: LynxView) {
        precondition(Thread.isMainThread)
        objc_setAssociatedObject(view, &scopeKey, scope, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func scope(for view: LynxView) -> LynxMonitorScope? {
        precondition(Thread.isMainThread)
        return objc_getAssociatedObject(view, &scopeKey) as? LynxMonitorScope
    }

    static func unbind(_ view: LynxView?) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak view] in unbind(view) }
            return
        }
        guard let view else { return }
        objc_setAssociatedObject(view, &scopeKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
