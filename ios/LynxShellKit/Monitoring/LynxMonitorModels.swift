import Foundation

public enum LynxMonitorEventType: String, Codable, CaseIterable {
    case lifecycle = "view.lifecycle", load = "view.load", performance = "lynx.performance"
    case jsError = "lynx.js_error", resource = "lynx.resource", diagnostic = "monitor.diagnostic"
}

public enum LynxMonitorVisibility: String, Codable { case visible, hidden, background, unknown }
public enum LynxMonitorContainerKind: String, Codable { case page, tab, embedded, unknown }
public enum LynxMonitorLoadKind: String, Codable { case initial, retry, reload }
public enum LynxMonitorAssociation: String, Codable { case exactLoad = "exact_load", exactView = "exact_view", unassigned }
public enum LynxMonitorSamplingOwner: String, Codable { case core, provider, none }
public enum LynxMonitorBundleSource: String, Codable { case ota, embedded, directHTTPS = "direct_https", directAsset = "direct_asset" }
public enum LynxMonitorIdentityStatus: String, Codable { case verified, computed, unavailable }

/** 只描述实际交给当前加载的字节；不持有 OTA Store 或可变 GlobalProps。 */
public struct LynxMonitorBundleIdentity: Encodable {
    public let source: LynxMonitorBundleSource
    public let lynxAppId: String?
    public let bundleName: String?
    public let releaseId: String?
    public let releaseSequence: String?
    public let sha256: String?
    public let identityStatus: LynxMonitorIdentityStatus
    public let missingReason: String?
    public let buildId: String?

    enum CodingKeys: String, CodingKey {
        case source, lynxAppId, bundleName, releaseId, releaseSequence, sha256, identityStatus, missingReason, buildId
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
        try c.encode(lynxAppId, forKey: .lynxAppId)
        try c.encode(bundleName, forKey: .bundleName)
        try c.encode(releaseId, forKey: .releaseId)
        try c.encode(releaseSequence, forKey: .releaseSequence)
        try c.encode(sha256, forKey: .sha256)
        try c.encode(identityStatus, forKey: .identityStatus)
        try c.encode(missingReason, forKey: .missingReason)
        try c.encode(buildId, forKey: .buildId)
    }
}

public struct LynxMonitorQuality: Encodable {
    public let association: LynxMonitorAssociation
    public let late: Bool
    public let missingFields: [String]
    public let invalidFields: [String]
    public let truncatedFields: [String]
}

public struct LynxMonitorSampling: Encodable {
    public let owner: LynxMonitorSamplingOwner
    public let rate: Double?
    enum CodingKeys: String, CodingKey { case owner, rate }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(owner, forKey: .owner)
        try c.encode(rate, forKey: .rate)
    }
}

public struct LynxMonitorMetric: Encodable {
    public enum Origin: String, Encodable { case sdkDuration = "sdk_duration", sdkDifference = "sdk_timestamp_difference" }
    public let name: String
    public let value: Double
    public let unit = "ms"
    public let origin: Origin
    public let sourceFields: [String]
}

public struct LynxMonitorPerformance: Encodable {
    public let entryType: String
    public let entryName: String
    public let identifier: String?
    public let metrics: [LynxMonitorMetric]
    public let timing: [String: Double]
    enum CodingKeys: String, CodingKey { case entryType, entryName, identifier, metrics, timing }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entryType, forKey: .entryType)
        try c.encode(entryName, forKey: .entryName)
        try c.encode(identifier, forKey: .identifier)
        try c.encode(metrics, forKey: .metrics)
        try c.encode(timing, forKey: .timing)
    }
}

public struct LynxMonitorErrorFrame: Encodable {
    public enum Position {
        case lineColumn(line: Int, column: Int)
        case functionPC(functionId: Int, pc: Int)
        case unknown
    }
    public let file: String?
    public let functionName: String?
    public let runtimeRelease: String?
    public let debugKey: String?
    public let position: Position
    enum CodingKeys: String, CodingKey {
        case file, functionName, runtimeRelease, debugKey, positionKind, line, column, functionId, pc
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(file, forKey: .file)
        try c.encode(functionName, forKey: .functionName)
        try c.encode(runtimeRelease, forKey: .runtimeRelease)
        try c.encode(debugKey, forKey: .debugKey)
        switch position {
        case let .lineColumn(line, column):
            try c.encode("line_column", forKey: .positionKind)
            try c.encode(line, forKey: .line)
            try c.encode(column, forKey: .column)
        case let .functionPC(functionId, pc):
            try c.encode("function_pc", forKey: .positionKind)
            try c.encode(functionId, forKey: .functionId)
            try c.encode(pc, forKey: .pc)
        case .unknown: try c.encode("unknown", forKey: .positionKind)
        }
    }
}

public struct LynxMonitorJSError: Encodable {
    public let errorCode: String?
    public let subCode: String?
    public let level: String
    public let realm: String
    public let message: String
    public let rawStack: String?
    public let frames: [LynxMonitorErrorFrame]
    public let handled: String
    public let phase: String
    enum CodingKeys: String, CodingKey { case errorCode, subCode, level, realm, message, rawStack, frames, handled, phase }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(errorCode, forKey: .errorCode)
        try c.encode(subCode, forKey: .subCode)
        try c.encode(level, forKey: .level)
        try c.encode(realm, forKey: .realm)
        try c.encode(message, forKey: .message)
        try c.encode(rawStack, forKey: .rawStack)
        try c.encode(frames, forKey: .frames)
        try c.encode(handled, forKey: .handled)
        try c.encode(phase, forKey: .phase)
    }
}

public enum LynxMonitorPayload: Encodable {
    public enum LifecycleState: String, Encodable { case created, visible, hidden, background, destroyed, createFailed = "create_failed" }
    public enum LoadPhase: String, Encodable {
        case started, resolved, loadedUnconfirmed = "loaded_unconfirmed", firstContent = "first_content", failed, cancelled, incomplete
    }
    case lifecycle(state: LifecycleState, durationMs: Double?)
    case load(phase: LoadPhase, reasonCode: String?, durationMs: Double?)
    case performance(LynxMonitorPerformance)
    case jsError(LynxMonitorJSError)
    case resource(resourceType: String, failed: Bool, errorCode: String?)
    case diagnostic(code: String, count: Int, detail: String?)

    public var eventType: LynxMonitorEventType {
        switch self {
        case .lifecycle: return .lifecycle
        case .load: return .load
        case .performance: return .performance
        case .jsError: return .jsError
        case .resource: return .resource
        case .diagnostic: return .diagnostic
        }
    }
    enum CodingKeys: String, CodingKey {
        case state, durationMs, phase, reasonCode, resourceType, outcome, errorCode, resourceKey, code, count, detail
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .performance(value): try value.encode(to: encoder)
        case let .jsError(value): try value.encode(to: encoder)
        default:
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .lifecycle(state, duration):
                try c.encode(state, forKey: .state)
                try c.encode(duration, forKey: .durationMs)
            case let .load(phase, reason, duration):
                try c.encode(phase, forKey: .phase)
                try c.encodeIfPresent(reason, forKey: .reasonCode)
                try c.encode(duration, forKey: .durationMs)
            case let .resource(type, failed, code):
                try c.encode(type, forKey: .resourceType)
                try c.encode(failed ? "failed" : "success", forKey: .outcome)
                try c.encode(code, forKey: .errorCode)
                try c.encodeNil(forKey: .durationMs)
                try c.encodeNil(forKey: .resourceKey)
            case let .diagnostic(code, count, detail):
                try c.encode(code, forKey: .code)
                try c.encode(count, forKey: .count)
                try c.encode(detail, forKey: .detail)
            case .performance, .jsError: break
            }
        }
    }
}

/** Provider 收到独立值快照；异步交付不会读取另一个 View 的当前版本。 */
public struct LynxMonitorEvent: Encodable {
    public let schemaVersion = "1.0"
    public let eventId: String
    public let processSessionId: String
    public let observedAtMs: Double
    public let platform = "ios"
    public let runtimeVersion: String
    public let hostBuild: String
    public let viewId: String?
    public let nativeInstanceId: String?
    public let containerKind: LynxMonitorContainerKind
    public let loadId: String?
    public let loadKind: LynxMonitorLoadKind?
    public let bundle: LynxMonitorBundleIdentity?
    public let visibility: LynxMonitorVisibility
    public let quality: LynxMonitorQuality
    public let sampling: LynxMonitorSampling
    public let payload: LynxMonitorPayload
    public var eventType: LynxMonitorEventType { payload.eventType }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, eventId, processSessionId, observedAtMs, platform, runtimeVersion, hostBuild
        case viewId, nativeInstanceId, containerKind, loadId, loadKind, bundle, visibility, quality, sampling, eventType, payload
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(eventId, forKey: .eventId)
        try c.encode(processSessionId, forKey: .processSessionId)
        try c.encode(observedAtMs, forKey: .observedAtMs)
        try c.encode(platform, forKey: .platform)
        try c.encode(runtimeVersion, forKey: .runtimeVersion)
        try c.encode(hostBuild, forKey: .hostBuild)
        try c.encode(viewId, forKey: .viewId)
        try c.encode(nativeInstanceId, forKey: .nativeInstanceId)
        try c.encode(containerKind, forKey: .containerKind)
        try c.encode(loadId, forKey: .loadId)
        try c.encode(loadKind, forKey: .loadKind)
        try c.encode(bundle, forKey: .bundle)
        try c.encode(visibility, forKey: .visibility)
        try c.encode(quality, forKey: .quality)
        try c.encode(sampling, forKey: .sampling)
        try c.encode(eventType, forKey: .eventType)
        try c.encode(payload, forKey: .payload)
    }
}
