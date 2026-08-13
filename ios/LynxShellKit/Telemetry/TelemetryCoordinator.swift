import Foundation

/// 采集器只旁路观察；默认使用 Noop Sink，绝不让监控失败阻塞 Router/OTA。
public protocol LynxTelemetrySink: AnyObject {
    func record(_ event: LynxTelemetryEvent)
}

/// 生产默认 Sink：不联网、不落盘，保留调用成本最低的 fail-open 行为。
public final class LynxNoopTelemetrySink: LynxTelemetrySink {
    public init() {}
    public func record(_ event: LynxTelemetryEvent) {}
}

/// 本地 Debug Sink，仅用于调试/单测，生产环境不得把它当作 durable uploader。
public final class LynxDebugTelemetrySink: LynxTelemetrySink {
    private let lock = NSLock()
    private var recordedEvents: [LynxTelemetryEvent] = []
    private let maxEvents: Int

    public init(maxEvents: Int = 500) {
        self.maxEvents = max(1, maxEvents)
    }

    public func record(_ event: LynxTelemetryEvent) {
        lock.lock()
        defer { lock.unlock() }
        recordedEvents.append(event)
        if recordedEvents.count > maxEvents {
            recordedEvents.removeFirst(recordedEvents.count - maxEvents)
        }
    }

    public func snapshot() -> [LynxTelemetryEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }
}

public struct LynxTelemetryConfiguration {
    public let platform: String
    public let hostMode: String
    public let hostApp: String
    public let appVersion: String
    public let buildNumber: String
    public let lynxSdkVersion: String
    public let engineVersion: String?
    public let runtimeKind: String
    public let sampleRate: Double
    public let samplingGroup: String
    public let samplingRuleVersion: String
    public let sink: LynxTelemetrySink

    public init(
        platform: String = "ios",
        hostMode: String = "view_controller",
        hostApp: String = Bundle.main.bundleIdentifier ?? "unknown",
        appVersion: String = "unknown",
        buildNumber: String = "unknown",
        lynxSdkVersion: String = "unknown",
        engineVersion: String? = nil,
        runtimeKind: String = "lynx_view",
        sampleRate: Double = 1.0,
        samplingGroup: String = "page_quality",
        samplingRuleVersion: String = "v1",
        sink: LynxTelemetrySink = LynxNoopTelemetrySink()
    ) {
        self.platform = platform
        self.hostMode = hostMode
        self.hostApp = hostApp
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.lynxSdkVersion = lynxSdkVersion
        self.engineVersion = engineVersion
        self.runtimeKind = runtimeKind
        self.sampleRate = min(max(sampleRate, 0), 1)
        self.samplingGroup = samplingGroup
        self.samplingRuleVersion = samplingRuleVersion
        self.sink = sink
    }
}

/// 单页的进程内状态。它只持有逻辑 Bundle 信息，不保存可上传的绝对路径。
public final class LynxTelemetryPageHandle {
    public let pageViewId: String
    public fileprivate(set) var identity: LynxTelemetryIdentity
    public fileprivate(set) var attemptedBundle: LynxAttemptedBundleSnapshot
    public fileprivate(set) var resolvedBundle: LynxResolvedBundleSnapshot?
    public fileprivate(set) var pageState: LynxTelemetryPageState = .allocated
    public fileprivate(set) var appState: LynxTelemetryAppState = .foreground
    public fileprivate(set) var pageOpenReported = false
    fileprivate var sequenceNo = 0
    fileprivate var attemptGeneration: Int
    fileprivate var activeStartedAtMonotonic: TimeInterval?

    fileprivate init(identity: LynxTelemetryIdentity, attempted: LynxAttemptedBundleSnapshot) {
        self.pageViewId = identity.pageViewId
        self.identity = identity
        self.attemptedBundle = attempted
        self.attemptGeneration = attempted.attemptGeneration
    }

    /// 重试/回滚必须创建新的 renderAttemptId，但保留 pageViewId/entryId。
    @discardableResult
    public func beginRenderAttempt(
        attempted: LynxAttemptedBundleSnapshot,
        transactionId: String? = nil
    ) -> LynxTelemetryIdentity {
        attemptGeneration = max(attemptGeneration + 1, attempted.attemptGeneration)
        identity = LynxTelemetryIdentity(
            navigationId: identity.navigationId,
            navigationSessionId: identity.navigationSessionId,
            entryId: identity.entryId,
            pageViewId: identity.pageViewId,
            renderAttemptId: UUID().uuidString,
            activationId: identity.activationId,
            transactionId: transactionId ?? identity.transactionId
        )
        attemptedBundle = attempted
        resolvedBundle = nil
        pageOpenReported = false
        return identity
    }
}

/// iOS 端本地 Telemetry 协调器；平台只提交事实，不猜测 Lynx 性能回调的到达顺序。
public final class LynxTelemetryCoordinator {
    public let configuration: LynxTelemetryConfiguration
    private let lock = NSLock()
    private var pagesById: [String: LynxTelemetryPageHandle] = [:]
    private var appState: LynxTelemetryAppState = .foreground
    private let processStartMonotonic = ProcessInfo.processInfo.systemUptime

    public init(configuration: LynxTelemetryConfiguration = LynxTelemetryConfiguration()) {
        self.configuration = configuration
    }

    /// Router 受理与页面身份创建分开；rejected 不会伪造 pageViewId。
    public func recordNavigationAdmission(
        navigationId: String,
        accepted: Bool,
        identity: LynxTelemetryIdentity? = nil,
        reason: String? = nil
    ) {
        let eventName = accepted ? "lynx.navigation.accepted" : "lynx.navigation.rejected"
        let handle = identity.flatMap { pagesById[$0.pageViewId] }
        emit(
            eventName: eventName,
            category: "router",
            source: "native",
            handle: handle,
            identityOverride: identity,
            attributes: reason.map { ["reason": .string(Self.safeString($0))] } ?? [:]
        )
    }

    @discardableResult
    public func startPage(
        identity: LynxTelemetryIdentity,
        attemptedBundle: LynxAttemptedBundleSnapshot
    ) -> LynxTelemetryPageHandle {
        let handle = LynxTelemetryPageHandle(identity: identity, attempted: attemptedBundle)
        lock.lock()
        pagesById[handle.pageViewId] = handle
        lock.unlock()
        handle.pageState = .registered
        emit(eventName: "lynx.page.identity_created", category: "page", source: "native", handle: handle)
        return handle
    }

    /// OTA prepare 成功后冻结 Resolved Snapshot；internalLocalPath 只留在内存。
    @discardableResult
    public func resolve(
        pageViewId: String,
        snapshot: LynxResolvedBundleSnapshot,
        renderAttemptId: String? = nil,
        generation: Int? = nil
    ) -> Bool {
        guard let handle = page(pageViewId), isCurrent(handle, renderAttemptId: renderAttemptId, generation: generation) else {
            return dropStaleCallback(pageViewId: pageViewId, renderAttemptId: renderAttemptId, generation: generation)
        }
        handle.resolvedBundle = snapshot
        emit(eventName: "ota.verify", category: "ota", source: "native", handle: handle)
        return true
    }

    public func markNavigationTransitionTerminal(
        pageViewId: String,
        status: LynxTelemetryTransitionTerminal,
        durationMs: Int64? = nil,
        reason: String? = nil
    ) {
        guard let handle = page(pageViewId) else { return }
        var attributes: [String: LynxTelemetryValue] = ["status": .string(status.rawValue)]
        if let durationMs { attributes["durationMs"] = .number(Double(max(0, durationMs))) }
        if let reason { attributes["reason"] = .string(Self.safeString(reason)) }
        emit(eventName: "lynx.transition.terminal", category: "router", source: "native", handle: handle, attributes: attributes)
    }

    public func markPageVisible(_ pageViewId: String, reason: String = "uikit_view_did_appear") {
        guard let handle = page(pageViewId), handle.pageState != .destroyed else { return }
        handle.pageState = .visible
        handle.appState = appState
        emit(eventName: "lynx.page.visibility_changed", category: "page", source: "native", handle: handle, attributes: ["state": .string("visible"), "reason": .string(Self.safeString(reason))])
        beginActivationIfEligible(handle, reason: reason)
    }

    public func markPageHidden(_ pageViewId: String, reason: String = "uikit_view_will_disappear") {
        guard let handle = page(pageViewId), handle.pageState != .destroyed else { return }
        endActivationIfNeeded(handle, reason: reason)
        handle.pageState = .hidden
        emit(eventName: "lynx.page.visibility_changed", category: "page", source: "native", handle: handle, attributes: ["state": .string("hidden"), "reason": .string(Self.safeString(reason))])
    }

    public func markPageDestroyed(_ pageViewId: String, reason: String = "uikit_view_did_disappear_pop") {
        guard let handle = page(pageViewId), handle.pageState != .destroyed else { return }
        endActivationIfNeeded(handle, reason: reason)
        handle.pageState = .destroyed
        emit(eventName: "lynx.page.destroyed", category: "page", source: "native", handle: handle, attributes: ["reason": .string(Self.safeString(reason))])
        lock.lock()
        pagesById.removeValue(forKey: pageViewId)
        lock.unlock()
    }

    public func markFirstScreen(
        pageViewId: String,
        renderAttemptId: String,
        generation: Int? = nil,
        durationMs: Int64? = nil
    ) {
        guard let handle = page(pageViewId), isCurrent(handle, renderAttemptId: renderAttemptId, generation: generation) else {
            _ = dropStaleCallback(pageViewId: pageViewId, renderAttemptId: renderAttemptId, generation: generation)
            return
        }
        emit(eventName: "lynx.page.first_screen", category: "page", source: "lynx_runtime", handle: handle, attributes: durationMs.map { ["durationMs": .number(Double(max(0, $0)))] } ?? [:])
        guard handle.resolvedBundle != nil, !handle.pageOpenReported else { return }
        handle.pageOpenReported = true
        emit(eventName: "lynx.ota.page_open", category: "ota", source: "lynx_runtime", handle: handle)
    }

    public func markRuntimeReady(pageViewId: String, renderAttemptId: String? = nil, generation: Int? = nil) {
        guard let handle = page(pageViewId), isCurrent(handle, renderAttemptId: renderAttemptId, generation: generation) else {
            _ = dropStaleCallback(pageViewId: pageViewId, renderAttemptId: renderAttemptId, generation: generation)
            return
        }
        emit(eventName: "lynx.page.runtime_ready", category: "page", source: "lynx_runtime", handle: handle)
    }

    /// App 生命周期与 UIViewController 页面可见性正交；SceneDelegate 应调用这两个入口。
    public func onApplicationBackground() {
        guard appState != .background else { return }
        appState = .background
        for handle in pages() {
            handle.appState = .background
            endActivationIfNeeded(handle, reason: "app_background")
            emit(eventName: "app.lifecycle.changed", category: "app", source: "system", handle: handle, attributes: ["state": .string("background")])
        }
    }

    public func onApplicationForeground() {
        guard appState != .foreground else { return }
        appState = .foreground
        for handle in pages() {
            handle.appState = .foreground
            emit(eventName: "app.lifecycle.changed", category: "app", source: "system", handle: handle, attributes: ["state": .string("foreground")])
            beginActivationIfEligible(handle, reason: "app_foreground")
        }
    }

    @discardableResult
    public func dropStaleCallback(
        pageViewId: String,
        renderAttemptId: String?,
        generation: Int?
    ) -> Bool {
        guard let handle = page(pageViewId) else { return false }
        guard !isCurrent(handle, renderAttemptId: renderAttemptId, generation: generation) else { return false }
        emit(eventName: "telemetry.stale_callback_dropped", category: "telemetry", source: "system", handle: handle, attributes: ["callbackRenderAttemptId": .string(Self.safeString(renderAttemptId ?? "unknown"))])
        return true
    }

    public func pages() -> [LynxTelemetryPageHandle] {
        lock.lock()
        defer { lock.unlock() }
        return Array(pagesById.values)
    }

    private func page(_ pageViewId: String) -> LynxTelemetryPageHandle? {
        lock.lock()
        defer { lock.unlock() }
        return pagesById[pageViewId]
    }

    private func isCurrent(_ handle: LynxTelemetryPageHandle, renderAttemptId: String?, generation: Int?) -> Bool {
        if let renderAttemptId, renderAttemptId != handle.identity.renderAttemptId { return false }
        if let generation, generation != handle.attemptGeneration { return false }
        return true
    }

    private func beginActivationIfEligible(_ handle: LynxTelemetryPageHandle, reason: String) {
        guard handle.pageState == .visible,
              handle.appState == .foreground,
              handle.resolvedBundle != nil,
              handle.activeStartedAtMonotonic == nil else { return }
        let activationId = UUID().uuidString
        handle.identity.activationId = activationId
        handle.activeStartedAtMonotonic = ProcessInfo.processInfo.systemUptime
        emit(eventName: "lynx.page.visibility_changed", category: "page", source: "native", handle: handle, attributes: ["activation": .string("started"), "reason": .string(Self.safeString(reason))])
    }

    private func endActivationIfNeeded(_ handle: LynxTelemetryPageHandle, reason: String) {
        guard let started = handle.activeStartedAtMonotonic else { return }
        let durationMs = max(0, Int64((ProcessInfo.processInfo.systemUptime - started) * 1000))
        emit(eventName: "lynx.page.visibility_changed", category: "page", source: "native", handle: handle, attributes: ["activation": .string("ended"), "reason": .string(Self.safeString(reason)), "durationMs": .number(Double(durationMs))])
        handle.activeStartedAtMonotonic = nil
        handle.identity.activationId = nil
    }

    private func emit(
        eventName: String,
        category: String,
        source: String,
        handle: LynxTelemetryPageHandle? = nil,
        identityOverride: LynxTelemetryIdentity? = nil,
        attributes: [String: LynxTelemetryValue] = [:]
    ) {
        guard Self.isSafeEventName(eventName) else { return }
        let identity = identityOverride ?? handle?.identity
        let sequence: Int
        if let handle {
            handle.sequenceNo += 1
            sequence = handle.sequenceNo
        } else {
            sequence = 0
        }
        let event = LynxTelemetryEvent(
            eventName: eventName,
            category: category,
            source: source,
            occurredAtUnixMs: Int64(Date().timeIntervalSince1970 * 1000),
            monotonicOffsetMs: Int64(max(0, (ProcessInfo.processInfo.systemUptime - processStartMonotonic) * 1000)),
            sequenceNo: sequence,
            identity: identity,
            runtimeKind: configuration.runtimeKind,
            runtimeInstanceId: handle?.pageViewId ?? "process",
            telemetryRouteKey: handle?.resolvedBundle?.telemetryRouteKey ?? handle?.attemptedBundle.telemetryRouteKey,
            hostMode: configuration.hostMode,
            platform: configuration.platform,
            hostApp: configuration.hostApp,
            appVersion: configuration.appVersion,
            buildNumber: configuration.buildNumber,
            lynxSdkVersion: configuration.lynxSdkVersion,
            engineVersion: handle?.resolvedBundle?.engineVersion ?? configuration.engineVersion,
            pageState: handle?.pageState,
            appState: handle?.appState ?? appState,
            attemptedBundle: handle?.attemptedBundle,
            resolvedBundle: handle?.resolvedBundle,
            sampleRate: configuration.sampleRate,
            samplingGroup: configuration.samplingGroup,
            samplingRuleVersion: configuration.samplingRuleVersion,
            attributes: attributes
        )
        // Sink 是扩展点，但不能把实现异常传播到导航线程；当前协议使用 non-throwing API。
        configuration.sink.record(event)
    }

    private static func safeString(_ value: String) -> String {
        let sanitized = value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return String(sanitized.prefix(256))
    }

    private static func isSafeEventName(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        for (index, character) in value.enumerated() {
            if index == 0 {
                guard character.isLetter, character.isLowercase else { return false }
            } else if !(character.isLetter || character.isNumber || character == "." || character == "_" || character == "-") {
                return false
            }
        }
        return true
    }
}
