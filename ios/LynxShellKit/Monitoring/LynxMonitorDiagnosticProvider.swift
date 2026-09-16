import Foundation

/** G1 本地验收用有界内存记录，不创建文件、不发送网络、不表示云端已收到。 */
public final class LynxMonitorDiagnosticProvider: LynxMonitorProvider {
    public let id = "ios.local_diagnostic.v1"
    public let capabilities = LynxMonitorProviderCapabilities(
        supportedEvents: Set(LynxMonitorEventType.allCases), perEventBundleContext: true,
        rawJsFrames: true, sdkOwnsRetry: false, flushSupported: false, samplingOwner: .core
    )
    private let lock = NSLock()
    private var ready = false
    private var events: [(event: LynxMonitorEvent, bytes: Int)] = []
    private var bytes = 0
    private var evicted = 0

    public init() {}

    public func initialize(context: LynxMonitorHostContext, completion: @escaping (LynxMonitorInitialization) -> Void) {
        lock.monitorLocked { ready = true }
        completion(.ready)
    }

    public func record(event: LynxMonitorEvent) throws -> LynxMonitorHandoff {
        let size = try JSONEncoder().encode(event).count
        return lock.monitorLocked {
            guard ready else { return .rejected(reason: "not_ready") }
            guard size <= 32 * 1024 else { return .rejected(reason: "invalid_event") }
            while events.count >= 128 || bytes + size > 512 * 1024 {
                bytes -= events.removeFirst().bytes
                evicted += 1
            }
            events.append((event, size))
            bytes += size
            return .recordedLocally
        }
    }

    public func snapshot() -> [LynxMonitorEvent] { lock.monitorLocked { events.map(\.event) } }
    public var evictedCount: Int { lock.monitorLocked { evicted } }

    public func dispose() {
        lock.monitorLocked {
            ready = false
            events.removeAll()
            bytes = 0
        }
    }
}
