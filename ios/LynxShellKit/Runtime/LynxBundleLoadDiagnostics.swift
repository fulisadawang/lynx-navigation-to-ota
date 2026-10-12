#if DEBUG
import Foundation

/** 仅 Debug 宿主基准使用，记录真实执行点，不记录 URL、请求头或用户数据。 */
struct LynxBundleLoadEvent: Sendable {
    let container: String
    let generation: UUID
    let phase: String
    let uptime: TimeInterval
    let onMainThread: Bool
    let byteCount: Int?
}

enum LynxBundleLoadDiagnostics {
    private static let lock = NSLock()
    private static var sink: ((LynxBundleLoadEvent) -> Void)?

    static func observe(_ observer: ((LynxBundleLoadEvent) -> Void)?) {
        lock.lock()
        sink = observer
        lock.unlock()
    }

    static func record(_ container: String, _ generation: UUID, _ phase: String, bytes: Int? = nil) {
        lock.lock()
        let observer = sink
        lock.unlock()
        observer?(.init(container: container, generation: generation, phase: phase,
                        uptime: ProcessInfo.processInfo.systemUptime,
                        onMainThread: Thread.isMainThread, byteCount: bytes))
    }
}
#endif
