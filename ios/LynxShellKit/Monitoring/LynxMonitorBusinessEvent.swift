import Foundation

public enum LynxMonitorBusinessValue: Encodable {
    case string(String)
    case number(Double)
    case boolean(Bool)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .boolean(value): try container.encode(value)
        }
    }
}

public struct LynxMonitorBusinessEvent: Encodable {
    public let group: String
    public let name: String
    public let attributes: [String: LynxMonitorBusinessValue]

    public init(group: String, name: String, attributes: [String: LynxMonitorBusinessValue]) {
        self.group = group
        self.name = name
        self.attributes = attributes
    }

    // 分组仅编码在 Event 外层，业务 payload 保持 name/attributes 形状。
    enum CodingKeys: String, CodingKey { case name, attributes }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(attributes, forKey: .attributes)
    }
}

enum LynxMonitorBusinessRejection: String, Error {
    case invalidArgument = "invalid_argument"
    case eventTooLarge = "event_too_large"
    case pageContextUnavailable = "page_context_unavailable"
    case notConfigured = "not_configured"
    case notReady = "not_ready"
    case monitorClosed = "monitor_closed"
    case eventUnsupported = "event_unsupported"
    case queueRejected = "queue_rejected"
    case internalError = "internal_error"

    var code: Int {
        switch self {
        case .invalidArgument, .eventTooLarge: return 1001
        case .pageContextUnavailable: return 1002
        case .notConfigured, .notReady, .monitorClosed, .eventUnsupported, .queueRejected: return 1004
        case .internalError: return 1500
        }
    }

    var message: String {
        switch self {
        case .invalidArgument: return "业务事件参数非法"
        case .eventTooLarge: return "业务事件超过容量限制"
        case .pageContextUnavailable: return "业务事件发送页面不可用"
        case .notConfigured: return "宿主未配置业务事件监控"
        case .notReady: return "监控当前无法接受事件"
        case .monitorClosed: return "监控已关闭"
        case .eventUnsupported: return "监控 Provider 不支持业务事件"
        case .queueRejected: return "监控队列无法接受本次业务事件"
        case .internalError: return "业务事件原生处理异常"
        }
    }
}

enum LynxMonitorAdmissionState: String { case initializing, ready }

enum LynxMonitorAdmissionResult {
    case queued(eventId: String, monitorState: LynxMonitorAdmissionState)
    case rejected(LynxMonitorBusinessRejection)

    var bridgeResult: NSDictionary {
        switch self {
        case let .queued(eventId, monitorState):
            return ["code": 0, "message": "业务事件已进入原生监控队列",
                    "data": ["stage": "queued", "eventId": eventId, "monitorState": monitorState.rawValue]]
        case let .rejected(reason):
            return ["code": reason.code, "message": reason.message,
                    "data": ["stage": "rejected", "reasonCode": reason.rawValue]]
        }
    }
}
