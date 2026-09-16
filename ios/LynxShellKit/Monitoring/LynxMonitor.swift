import Foundation
import Lynx

public struct LynxMonitorHostContext {
    public let platform = "ios"
    public let hostAppId: String
    public let hostBuild: String
    public let runtimeVersion: String
    public let processSessionId: String
}

public struct LynxMonitorProviderCapabilities {
    public let platform: String
    public let supportedEvents: Set<LynxMonitorEventType>
    public let perEventBundleContext: Bool
    public let rawJsFrames: Bool
    public let sdkOwnsRetry: Bool
    public let flushSupported: Bool
    public let samplingOwner: LynxMonitorSamplingOwner

    public init(platform: String = "ios", supportedEvents: Set<LynxMonitorEventType>,
                perEventBundleContext: Bool, rawJsFrames: Bool, sdkOwnsRetry: Bool,
                flushSupported: Bool, samplingOwner: LynxMonitorSamplingOwner) {
        self.platform = platform
        self.supportedEvents = supportedEvents
        self.perEventBundleContext = perEventBundleContext
        self.rawJsFrames = rawJsFrames
        self.sdkOwnsRetry = sdkOwnsRetry
        self.flushSupported = flushSupported
        self.samplingOwner = samplingOwner
    }
}

public enum LynxMonitorInitialization { case ready, failed(reason: String) }
public enum LynxMonitorHandoff { case acceptedBySDK, recordedLocally, rejected(reason: String) }
public enum LynxMonitorFlush { case completedSDKFlush, unsupported, timedOut, failed }

public protocol LynxMonitorProvider: AnyObject {
    var id: String { get }
    var capabilities: LynxMonitorProviderCapabilities { get }
    func initialize(context: LynxMonitorHostContext, completion: @escaping (LynxMonitorInitialization) -> Void)
    func record(event: LynxMonitorEvent) throws -> LynxMonitorHandoff
    func flush(timeoutMs: Int, completion: @escaping (LynxMonitorFlush) -> Void)
    func dispose()
}

public extension LynxMonitorProvider {
    func flush(timeoutMs: Int, completion: @escaping (LynxMonitorFlush) -> Void) { completion(.unsupported) }
}

public struct LynxMonitorConfig {
    public let enabled: Bool
    public let provider: LynxMonitorProvider?
    public let performanceSampleRate: Double
    /** 仅处理 message / stack，在监控线程调用；业务特有隐私规则由宿主明确提供。 */
    public let redactText: ((String) -> String)?
    public init(enabled: Bool, provider: LynxMonitorProvider?, performanceSampleRate: Double = 1,
                redactText: ((String) -> String)? = nil) {
        self.enabled = enabled
        self.provider = provider
        self.performanceSampleRate = performanceSampleRate
        self.redactText = redactText
    }
}

public enum LynxMonitorInstallResult: Equatable {
    case disabled, notConfigured, initializing, alreadyInstalled, rejected(reason: String)
}

public struct LynxMonitorDiagnostics {
    public let state: String
    public let queuedCount: Int
    public let queuedBytes: Int
    public let counters: [String: Int]
}

/** 进程只有一个 Provider；关闭某个页面不会关闭其他页面共用的 SDK。 */
public enum LynxMonitor {
    private static let lock = NSLock()
    private static var runtime: LynxMonitorRuntime?

    @discardableResult
    public static func install(_ config: LynxMonitorConfig) -> LynxMonitorInstallResult {
        lock.lock()
        defer { lock.unlock() }
        if let current = runtime {
            guard config.enabled, let provider = config.provider,
                  current.provider === provider,
                  current.sampleRate == config.performanceSampleRate else {
                return .rejected(reason: "already_initialized")
            }
            return .alreadyInstalled
        }
        guard config.enabled else { return .disabled }
        guard let provider = config.provider else { return .notConfigured }
        guard config.performanceSampleRate.isFinite, (0 ... 1).contains(config.performanceSampleRate) else {
            return .rejected(reason: "invalid_sample_rate")
        }
        let capabilities = provider.capabilities
        guard capabilities.platform == "ios", capabilities.perEventBundleContext,
              capabilities.rawJsFrames, capabilities.samplingOwner != .none,
              capabilities.supportedEvents.contains(.performance),
              capabilities.supportedEvents.contains(.jsError) else {
            return .rejected(reason: "incompatible_provider")
        }
        guard capabilities.samplingOwner != .provider || config.performanceSampleRate == 1 else {
            return .rejected(reason: "sampling_conflict")
        }
        do {
            let owner = Bundle(for: LynxVersion.self)
            let metadata = [owner, Bundle.main].compactMap { container -> LynxSDKVersionMetadata? in
                guard let url = container.url(forResource: "LynxResources", withExtension: "bundle"),
                      let resource = Bundle(url: url) else { return nil }
                return .init(identifier: resource.bundleIdentifier,
                             version: resource.infoDictionary?["CFBundleShortVersionString"] as? String)
            }
            let framework = owner.bundleURL.pathExtension == "framework"
                ? LynxSDKVersionMetadata(identifier: owner.bundleIdentifier,
                                         version: owner.infoDictionary?["CFBundleShortVersionString"] as? String) : nil
            let version = try LynxSDKVersionResolver.resolve(resources: metadata, framework: framework,
                                                             normalize: OtaUserContext.normalizeLynxSdkVersion)
            guard let appId = Bundle.main.bundleIdentifier,
                  let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String, !build.isEmpty else {
                return .rejected(reason: "host_metadata_unavailable")
            }
            let context = LynxMonitorHostContext(hostAppId: appId, hostBuild: build,
                                                runtimeVersion: version, processSessionId: UUID().uuidString)
            let created = LynxMonitorRuntime(config: config, provider: provider, context: context)
            runtime = created
            created.start()
            return .initializing
        } catch {
            return .rejected(reason: "runtime_version_unavailable")
        }
    }

    public static func diagnostics() -> LynxMonitorDiagnostics {
        let current = lock.monitorLocked { runtime }
        return current?.diagnostics() ?? .init(state: "disabled", queuedCount: 0, queuedBytes: 0, counters: [:])
    }

    public static func shutdown() {
        let previous = lock.monitorLocked { () -> LynxMonitorRuntime? in
            let previous = runtime
            runtime = nil
            return previous
        }
        previous?.dispose()
    }

    static func beginView(kind: LynxMonitorContainerKind, loadKind: LynxMonitorLoadKind,
                          visibility: LynxMonitorVisibility) -> LynxMonitorScope? {
        let current = lock.monitorLocked { runtime }
        guard let current, current.canCapture else { return nil }
        return LynxMonitorScope(runtime: current, kind: kind, loadKind: loadKind, visibility: visibility)
    }
}

final class LynxMonitorRuntime {
    let provider: LynxMonitorProvider
    let context: LynxMonitorHostContext
    let sampleRate: Double
    let capabilities: LynxMonitorProviderCapabilities
    private let redactText: ((String) -> String)?
    private let lock = NSLock()
    private let executor = DispatchQueue(label: "com.lynxshell.monitor.delivery", qos: .utility)
    private var state = "initializing"
    private var pending: [(event: LynxMonitorEvent, bytes: Int)] = []
    private var pendingBytes = 0
    private var draining = false
    private var providerDisposed = false
    private var counters: [String: Int] = [:]

    init(config: LynxMonitorConfig, provider: LynxMonitorProvider, context: LynxMonitorHostContext) {
        self.provider = provider
        self.context = context
        self.sampleRate = config.performanceSampleRate
        self.capabilities = provider.capabilities
        self.redactText = config.redactText
    }

    var canCapture: Bool { lock.monitorLocked { state == "initializing" || state == "ready" } }

    func start() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.finishInitialization(.failed(reason: "initialization_timeout"))
        }
        executor.async { [weak self] in
            guard let self, self.canCapture else { return }
            self.provider.initialize(context: self.context) { [weak self] result in
                self?.finishInitialization(result)
            }
        }
    }

    private func finishInitialization(_ result: LynxMonitorInitialization) {
        lock.lock()
        guard state == "initializing" else { lock.unlock(); return }
        switch result {
        case .ready:
            state = "ready"
            scheduleDrainLocked()
        case let .failed(reason):
            state = "failed"
            incrementLocked(reason == "initialization_timeout" ? reason : "initialization_failed")
            incrementLocked("discarded_count", by: pending.count)
            pending.removeAll()
            pendingBytes = 0
            scheduleProviderDisposeLocked()
        }
        lock.unlock()
    }

    func counts(_ code: String, by amount: Int = 1) {
        lock.monitorLocked { incrementLocked(code, by: amount) }
    }

    func enqueue(_ event: LynxMonitorEvent) {
        // 只做有界字段的容量估算，JSON 编码和 Provider 调用留在串行消费线程。
        let bytes = event.monitorBudgetBytes
        lock.lock()
        defer { lock.unlock() }
        guard state == "initializing" || state == "ready" else { incrementLocked("discarded_inactive"); return }
        guard capabilities.supportedEvents.contains(event.eventType) else { incrementLocked("unsupported_event"); return }
        guard bytes <= 32 * 1024 else { incrementLocked("event_too_large"); return }
        while pending.count >= 128 || pendingBytes + bytes > 512 * 1024 {
            let index = pending.firstIndex { $0.event.eventType == .performance || $0.event.eventType == .resource } ?? 0
            let removed = pending.remove(at: index)
            pendingBytes -= removed.bytes
            incrementLocked("dropped_\(removed.event.eventType.rawValue)")
        }
        pending.append((event, bytes))
        pendingBytes += bytes
        if state == "ready" { scheduleDrainLocked() }
    }

    private func scheduleDrainLocked() {
        guard !draining, !pending.isEmpty else { return }
        draining = true
        executor.async { [weak self] in self?.drain() }
    }

    private func drain() {
        while true {
            let next = lock.monitorLocked { () -> LynxMonitorEvent? in
                guard state == "ready", !pending.isEmpty else { draining = false; return nil }
                let next = pending.removeFirst()
                pendingBytes -= next.bytes
                return next.event
            }
            guard let next else { return }
            let event = LynxMonitorSanitizer.process(next, customRedactor: redactText)
            do {
                let encoded = try JSONEncoder().encode(event)
                guard encoded.count <= 32 * 1024 else { counts("event_too_large"); continue }
                guard canCapture else { counts("discarded_inactive"); continue }
                switch try provider.record(event: event) {
                case .acceptedBySDK: counts("accepted_by_sdk")
                case .recordedLocally: counts("recorded_locally")
                case .rejected: counts("provider_rejected")
                }
            } catch {
                counts("provider_error")
            }
        }
    }

    func diagnostics() -> LynxMonitorDiagnostics {
        lock.monitorLocked { .init(state: state, queuedCount: pending.count, queuedBytes: pendingBytes, counters: counters) }
    }

    func dispose() {
        let changed = lock.monitorLocked { () -> Bool in
            guard state != "disposed" else { return false }
            state = "disposed"
            incrementLocked("discarded_count", by: pending.count)
            pending.removeAll()
            pendingBytes = 0
            return true
        }
        if changed {
            lock.monitorLocked { scheduleProviderDisposeLocked() }
        }
    }

    private func scheduleProviderDisposeLocked() {
        guard !providerDisposed else { return }
        providerDisposed = true
        executor.async { [provider] in provider.dispose() }
    }

    private func incrementLocked(_ code: String, by amount: Int = 1) {
        counters[code] = min(Int.max - amount, counters[code, default: 0]) + amount
    }
}

extension NSLock {
    func monitorLocked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
