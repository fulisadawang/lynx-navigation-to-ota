import Foundation

/** 主线程上的进程共享系统状态，页面只释放自己的租约，最后一个恢复 App 原值。 */
final class LynxNativeAppBooleanLeases {
    private let read: () -> Bool
    private let write: (Bool) -> Void
    private var owners = Set<String>()
    private var previous = false

    init(read: @escaping () -> Bool, write: @escaping (Bool) -> Void) {
        self.read = read
        self.write = write
    }

    func acquire(ownerID: String) {
        precondition(Thread.isMainThread)
        if owners.isEmpty { previous = read() }
        owners.insert(ownerID)
        write(true)
    }

    func release(ownerID: String) {
        precondition(Thread.isMainThread)
        guard owners.remove(ownerID) != nil else { return }
        if owners.isEmpty { write(previous) }
    }
}
