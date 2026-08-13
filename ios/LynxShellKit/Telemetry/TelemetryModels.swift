import Foundation

/// Wire Schema 3.0.0 中允许的 Bundle 来源。
public enum LynxTelemetryBundleSource: String, Codable, Equatable {
    case ota
    case directHttps = "direct_https"
    case assets
    case localFile = "local_file"
}

/// 允许业务属性进入事件的四种基础类型；Native 字段不能由页面覆盖。
public enum LynxTelemetryValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// 一个 Native Page Stack 页面在 Telemetry 中使用的四层身份。
public struct LynxTelemetryIdentity: Codable, Equatable {
    public let navigationId: String
    public let navigationSessionId: String
    public let entryId: String
    public let pageViewId: String
    public let renderAttemptId: String
    public var activationId: String?
    public var transactionId: String?

    public init(
        navigationId: String = UUID().uuidString,
        navigationSessionId: String,
        entryId: String,
        pageViewId: String = UUID().uuidString,
        renderAttemptId: String = UUID().uuidString,
        activationId: String? = nil,
        transactionId: String? = nil
    ) {
        self.navigationId = navigationId
        self.navigationSessionId = navigationSessionId
        self.entryId = entryId
        self.pageViewId = pageViewId
        self.renderAttemptId = renderAttemptId
        self.activationId = activationId
        self.transactionId = transactionId
    }
}

/// prepare() 前冻结的候选 Bundle 快照。路径只允许在进程内使用，不能放入该模型。
public struct LynxAttemptedBundleSnapshot: Codable, Equatable {
    public let kind: String
    public let bundleSource: LynxTelemetryBundleSource
    public let lynxAppId: String?
    public let bundleName: String
    public let telemetryRouteKey: String
    public let otaOperationId: String?
    public let candidateReleaseId: String?
    public let expectedSha256: String?
    public let prepareStartedAtUnixMs: Int64
    public let attemptGeneration: Int

    public init(
        source: LynxTelemetryBundleSource,
        bundleName: String,
        telemetryRouteKey: String,
        lynxAppId: String? = nil,
        otaOperationId: String? = nil,
        candidateReleaseId: String? = nil,
        expectedSha256: String? = nil,
        prepareStartedAtUnixMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        attemptGeneration: Int = 1
    ) {
        self.kind = "attempted"
        self.bundleSource = source
        self.lynxAppId = lynxAppId
        self.bundleName = bundleName
        self.telemetryRouteKey = telemetryRouteKey
        self.otaOperationId = otaOperationId
        self.candidateReleaseId = candidateReleaseId
        self.expectedSha256 = expectedSha256
        self.prepareStartedAtUnixMs = prepareStartedAtUnixMs
        self.attemptGeneration = attemptGeneration
    }
}

/// prepare 成功且完成 SHA/Release 选择后冻结的实际 Bundle 快照。
public struct LynxResolvedBundleSnapshot: Codable, Equatable {
    public let kind: String
    public let bundleSource: LynxTelemetryBundleSource
    public let lynxAppId: String?
    public let bundleName: String
    public let telemetryRouteKey: String
    public let releaseId: String?
    public let bundleSha256: String?
    public let engineVersion: String?
    public let localGeneration: String?
    public let rollbackFromReleaseId: String?
    public let resolvedAtUnixMs: Int64

    /// 绝对路径只在当前进程传给 LynxView，Codable 明确排除，避免日志/队列泄露路径。
    public let internalLocalPath: String?

    public init(
        source: LynxTelemetryBundleSource,
        bundleName: String,
        telemetryRouteKey: String,
        lynxAppId: String? = nil,
        releaseId: String? = nil,
        bundleSha256: String? = nil,
        engineVersion: String? = nil,
        localGeneration: String? = nil,
        rollbackFromReleaseId: String? = nil,
        resolvedAtUnixMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        internalLocalPath: String? = nil
    ) {
        self.kind = "resolved"
        self.bundleSource = source
        self.lynxAppId = lynxAppId
        self.bundleName = bundleName
        self.telemetryRouteKey = telemetryRouteKey
        self.releaseId = releaseId
        self.bundleSha256 = bundleSha256
        self.engineVersion = engineVersion
        self.localGeneration = localGeneration
        self.rollbackFromReleaseId = rollbackFromReleaseId
        self.resolvedAtUnixMs = resolvedAtUnixMs
        self.internalLocalPath = internalLocalPath
    }

    private enum CodingKeys: String, CodingKey {
        case kind, bundleSource, lynxAppId, bundleName, telemetryRouteKey
        case releaseId, bundleSha256, engineVersion, localGeneration
        case rollbackFromReleaseId, resolvedAtUnixMs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decode(String.self, forKey: .kind)
        self.bundleSource = try container.decode(LynxTelemetryBundleSource.self, forKey: .bundleSource)
        self.lynxAppId = try container.decodeIfPresent(String.self, forKey: .lynxAppId)
        self.bundleName = try container.decode(String.self, forKey: .bundleName)
        self.telemetryRouteKey = try container.decode(String.self, forKey: .telemetryRouteKey)
        self.releaseId = try container.decodeIfPresent(String.self, forKey: .releaseId)
        self.bundleSha256 = try container.decodeIfPresent(String.self, forKey: .bundleSha256)
        self.engineVersion = try container.decodeIfPresent(String.self, forKey: .engineVersion)
        self.localGeneration = try container.decodeIfPresent(String.self, forKey: .localGeneration)
        self.rollbackFromReleaseId = try container.decodeIfPresent(String.self, forKey: .rollbackFromReleaseId)
        self.resolvedAtUnixMs = try container.decode(Int64.self, forKey: .resolvedAtUnixMs)
        // 绝对路径不会从 Wire/磁盘反序列化回来。
        self.internalLocalPath = nil
    }
}

public enum LynxTelemetryPageState: String, Codable, Equatable {
    case allocated
    case registered
    case visible
    case hidden
    case destroyed
}

public enum LynxTelemetryAppState: String, Codable, Equatable {
    case foreground
    case background
}

/// Wire 层的正交页面/App/渲染状态；页面状态不能代替 App 前后台状态。
public struct LynxTelemetryLifecycleSnapshot: Codable, Equatable {
    public let pageState: LynxTelemetryPageState
    public let appState: LynxTelemetryAppState
    public let attemptState: String
    public let activeEligible: Bool
    public let reason: String?

    public init(pageState: LynxTelemetryPageState, appState: LynxTelemetryAppState, attemptState: String, activeEligible: Bool, reason: String? = nil) {
        self.pageState = pageState
        self.appState = appState
        self.attemptState = attemptState
        self.activeEligible = activeEligible
        self.reason = reason
    }
}

public struct LynxTelemetryNavigationSnapshot: Codable, Equatable {
    public let state: String
    public let rejectionCode: String?

    public init(state: String, rejectionCode: String? = nil) {
        self.state = state
        self.rejectionCode = rejectionCode
    }
}

public struct LynxTelemetryTransitionSnapshot: Codable, Equatable {
    public let state: String
    public let terminal: LynxTelemetryTransitionTerminal?
    public let durationMs: Int64?

    public init(state: String, terminal: LynxTelemetryTransitionTerminal? = nil, durationMs: Int64? = nil) {
        self.state = state
        self.terminal = terminal
        self.durationMs = durationMs
    }
}

public struct LynxTelemetryPrivacySnapshot: Codable, Equatable {
    public let consentState: String
    public let subjectRefPresent: Bool
    public let optOut: Bool

    public init(consentState: String, subjectRefPresent: Bool, optOut: Bool) {
        self.consentState = consentState
        self.subjectRefPresent = subjectRefPresent
        self.optOut = optOut
    }
}

public enum LynxTelemetryTransitionTerminal: String, Codable, Equatable {
    case completed
    case degraded
    case cancelled
    case failed
    case notApplicable = "notApplicable"
}

/// Wire Schema 3.0.0 的本地事件对象；此阶段只交给 Noop/Debug Sink。
public struct LynxTelemetryEvent: Codable, Equatable {
    public let schemaVersion: String
    public let eventId: String
    public let eventName: String
    public let category: String
    public let source: String
    public let occurredAtUnixMs: Int64
    public let monotonicOffsetMs: Int64
    public let sequenceNo: Int
    public let navigationId: String?
    public let navigationSessionId: String?
    public let pageViewId: String?
    public let entryId: String?
    public let renderAttemptId: String?
    public let activationId: String?
    public let transactionId: String?
    public let runtimeKind: String
    public let runtimeInstanceId: String
    public let telemetryRouteKey: String
    public let hostMode: String
    public let platform: String
    public let hostApp: String
    public let appVersion: String
    public let buildNumber: String
    public let lynxSdkVersion: String
    public let engineVersion: String
    /// 兼容进程内调用方；Wire 编码只输出 lifecycle 对象，不输出这两个顶层旧字段。
    public var pageState: LynxTelemetryPageState? = nil
    public var appState: LynxTelemetryAppState? = nil
    public let lifecycle: LynxTelemetryLifecycleSnapshot?
    public let navigationAdmission: LynxTelemetryNavigationSnapshot?
    public let transition: LynxTelemetryTransitionSnapshot?
    public let privacy: LynxTelemetryPrivacySnapshot
    public let attemptedBundleSnapshot: LynxAttemptedBundleSnapshot?
    public let resolvedBundleSnapshot: LynxResolvedBundleSnapshot?
    public let sampleRate: Double
    public let samplingGroup: String
    public let samplingRuleVersion: String
    public let analysisEligible: Bool
    public let deliveryOwner: String
    public let attributes: [String: LynxTelemetryValue]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, eventId, eventName, category, source
        case occurredAtUnixMs, monotonicOffsetMs, sequenceNo
        case navigationId, navigationSessionId, pageViewId, entryId, renderAttemptId, activationId, transactionId
        case runtimeKind, runtimeInstanceId, telemetryRouteKey, hostMode, platform, hostApp, appVersion, buildNumber
        case lynxSdkVersion, engineVersion, attemptedBundleSnapshot, resolvedBundleSnapshot
        case lifecycle, navigationAdmission, transition, sampleRate, samplingGroup, samplingRuleVersion
        case analysisEligible, deliveryOwner, privacy, attributes
    }

    public init(
        eventName: String,
        category: String,
        source: String,
        occurredAtUnixMs: Int64,
        monotonicOffsetMs: Int64,
        sequenceNo: Int,
        identity: LynxTelemetryIdentity?,
        runtimeKind: String,
        runtimeInstanceId: String,
        telemetryRouteKey: String?,
        hostMode: String,
        platform: String,
        hostApp: String,
        appVersion: String,
        buildNumber: String,
        lynxSdkVersion: String,
        engineVersion: String?,
        pageState: LynxTelemetryPageState?,
        appState: LynxTelemetryAppState?,
        attemptedBundle: LynxAttemptedBundleSnapshot?,
        resolvedBundle: LynxResolvedBundleSnapshot?,
        sampleRate: Double,
        samplingGroup: String,
        samplingRuleVersion: String,
        analysisEligible: Bool = true,
        deliveryOwner: String = "internal",
        lifecycle: LynxTelemetryLifecycleSnapshot? = nil,
        navigationAdmission: LynxTelemetryNavigationSnapshot? = nil,
        transition: LynxTelemetryTransitionSnapshot? = nil,
        privacy: LynxTelemetryPrivacySnapshot = LynxTelemetryPrivacySnapshot(consentState: "unknown", subjectRefPresent: false, optOut: false),
        attributes: [String: LynxTelemetryValue]
    ) {
        self.schemaVersion = "3.0.0"
        self.eventId = "evt_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        self.eventName = eventName
        self.category = category
        self.source = source
        self.occurredAtUnixMs = occurredAtUnixMs
        self.monotonicOffsetMs = monotonicOffsetMs
        self.sequenceNo = sequenceNo
        self.navigationId = identity?.navigationId
        self.navigationSessionId = identity?.navigationSessionId
        self.pageViewId = identity?.pageViewId
        self.entryId = identity?.entryId
        self.renderAttemptId = identity?.renderAttemptId
        self.activationId = identity?.activationId
        self.transactionId = identity?.transactionId
        self.runtimeKind = runtimeKind
        self.runtimeInstanceId = runtimeInstanceId
        self.telemetryRouteKey = telemetryRouteKey ?? "unknown"
        self.hostMode = hostMode
        self.platform = platform
        self.hostApp = hostApp
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.lynxSdkVersion = lynxSdkVersion
        self.engineVersion = engineVersion ?? "unknown"
        self.pageState = pageState
        self.appState = appState
        self.lifecycle = lifecycle ?? pageState.map {
            LynxTelemetryLifecycleSnapshot(
                pageState: $0,
                appState: appState ?? .background,
                attemptState: resolvedBundle == nil ? "unusable" : "usable",
                activeEligible: $0 == .visible && (appState ?? .background) == .foreground && resolvedBundle != nil,
                reason: nil
            )
        }
        self.navigationAdmission = navigationAdmission
        self.transition = transition
        self.privacy = privacy
        self.attemptedBundleSnapshot = attemptedBundle
        self.resolvedBundleSnapshot = resolvedBundle
        self.sampleRate = sampleRate
        self.samplingGroup = samplingGroup
        self.samplingRuleVersion = samplingRuleVersion
        self.analysisEligible = analysisEligible
        self.deliveryOwner = deliveryOwner
        self.attributes = attributes
    }

    /// 只编码共享 Wire Schema 字段，避免把旧的顶层 pageState/appState 写成非法额外字段。
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(eventId, forKey: .eventId)
        try container.encode(eventName, forKey: .eventName)
        try container.encode(category, forKey: .category)
        try container.encode(source, forKey: .source)
        try container.encode(occurredAtUnixMs, forKey: .occurredAtUnixMs)
        try container.encode(monotonicOffsetMs, forKey: .monotonicOffsetMs)
        try container.encode(sequenceNo, forKey: .sequenceNo)
        try container.encodeIfPresent(navigationId, forKey: .navigationId)
        try container.encodeIfPresent(navigationSessionId, forKey: .navigationSessionId)
        try container.encodeIfPresent(pageViewId, forKey: .pageViewId)
        try container.encodeIfPresent(entryId, forKey: .entryId)
        try container.encodeIfPresent(renderAttemptId, forKey: .renderAttemptId)
        try container.encodeIfPresent(activationId, forKey: .activationId)
        try container.encodeIfPresent(transactionId, forKey: .transactionId)
        try container.encode(runtimeKind, forKey: .runtimeKind)
        try container.encode(runtimeInstanceId, forKey: .runtimeInstanceId)
        try container.encode(telemetryRouteKey, forKey: .telemetryRouteKey)
        try container.encode(hostMode, forKey: .hostMode)
        try container.encode(platform, forKey: .platform)
        try container.encode(hostApp, forKey: .hostApp)
        try container.encode(appVersion, forKey: .appVersion)
        try container.encode(buildNumber, forKey: .buildNumber)
        try container.encode(lynxSdkVersion, forKey: .lynxSdkVersion)
        try container.encode(engineVersion, forKey: .engineVersion)
        try container.encodeIfPresent(attemptedBundleSnapshot, forKey: .attemptedBundleSnapshot)
        try container.encodeIfPresent(resolvedBundleSnapshot, forKey: .resolvedBundleSnapshot)
        try container.encodeIfPresent(lifecycle, forKey: .lifecycle)
        try container.encodeIfPresent(navigationAdmission, forKey: .navigationAdmission)
        try container.encodeIfPresent(transition, forKey: .transition)
        try container.encode(sampleRate, forKey: .sampleRate)
        try container.encode(samplingGroup, forKey: .samplingGroup)
        try container.encode(samplingRuleVersion, forKey: .samplingRuleVersion)
        try container.encode(analysisEligible, forKey: .analysisEligible)
        try container.encode(deliveryOwner, forKey: .deliveryOwner)
        try container.encode(privacy, forKey: .privacy)
        try container.encode(attributes, forKey: .attributes)
    }
}
