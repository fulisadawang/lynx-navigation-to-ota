import Foundation
import Lynx

/** 一个活体 Lynx 页面在跨端 Router 协议中的稳定身份。 */
public struct LynxRouterPageInfo {
    public let pageId: String
    public let containerId: String
    public let pageKey: String
    public let hostMode: String

    public init(pageId: String, containerId: String, pageKey: String, hostMode: String) {
        self.pageId = pageId
        self.containerId = containerId
        self.pageKey = pageKey
        self.hostMode = hostMode
    }
}

/** 页面发给 iOS 宿主的消息。 */
public struct LynxRouterMessage {
    public let source: LynxRouterPageInfo
    public let eventName: String
    public let payload: [String: Any]
}

/** 宿主处理 JS -> Native 消息后的统一回复。 */
public struct LynxRouterMessageReply {
    public let accepted: Bool
    public let message: String
    public let data: [String: Any]

    public init(
        accepted: Bool = true,
        message: String = "消息已处理",
        data: [String: Any] = [:]
    ) {
        self.accepted = accepted
        self.message = message
        self.data = data
    }
}

/** iOS 宿主可选安装的双向消息处理器。 */
public typealias LynxRouterMessageHandler = (LynxRouterMessage) -> LynxRouterMessageReply

/**
 * 进程内 Lynx 页面消息中心。
 *
 * 只保存 LynxView 弱引用；UIViewController 销毁或原位换 Bundle 时必须注销，避免把
 * 消息投递到旧页面。事件最终都在主线程触发，和 UIKit/Lynx 的线程约束一致。
 */
enum ShellMessageHub {
    static let lifecycleEvent = "lynxRouterLifecycle"

    private final class Endpoint {
        let info: LynxRouterPageInfo
        weak var view: LynxView?

        init(info: LynxRouterPageInfo, view: LynxView) {
            self.info = info
            self.view = view
        }
    }

    private static var endpoints: [String: Endpoint] = [:]
    private static var messageHandler: LynxRouterMessageHandler?

    static func setMessageHandler(_ handler: LynxRouterMessageHandler?) {
        messageHandler = handler
    }

    static func register(info: LynxRouterPageInfo, view: LynxView) {
        endpoints[info.pageId] = Endpoint(info: info, view: view)
    }

    static func unregister(pageId: String) {
        endpoints.removeValue(forKey: pageId)
    }

    static func pages() -> [LynxRouterPageInfo] {
        prune()
        return endpoints.values.map { $0.info }.sorted { $0.pageId < $1.pageId }
    }

    static func pageId(for view: LynxView) -> String? {
        prune()
        return endpoints.first { $0.value.view === view }?.key
    }

    static func dispatchFromPage(
        view: LynxView,
        eventName: String,
        payload: [String: Any]
    ) -> LynxRouterMessageReply {
        guard let pageId = pageId(for: view), let endpoint = endpoints[pageId] else {
            return LynxRouterMessageReply(accepted: false, message: "页面已销毁或 pageId 已失效")
        }
        guard let messageHandler else {
            return LynxRouterMessageReply(
                accepted: false,
                message: "宿主尚未安装 LynxRouterMessageHandler"
            )
        }
        do {
            try validateEventName(eventName, allowLifecycle: true)
            return messageHandler(
                LynxRouterMessage(source: endpoint.info, eventName: eventName, payload: payload)
            )
        } catch {
            return LynxRouterMessageReply(accepted: false, message: error.localizedDescription)
        }
    }

    @discardableResult
    static func broadcast(eventName: String, payload: [String: Any]) throws -> Int {
        try validateEventName(eventName, allowLifecycle: false)
        let live = liveEndpoints()
        live.forEach { post($0, eventName: eventName, payload: payload) }
        return live.count
    }

    static func sendToPage(
        pageId: String,
        eventName: String,
        payload: [String: Any]
    ) throws -> Bool {
        try validateEventName(eventName, allowLifecycle: false)
        guard let endpoint = endpoints[pageId], endpoint.view != nil else {
            endpoints.removeValue(forKey: pageId)
            return false
        }
        post(endpoint, eventName: eventName, payload: payload)
        return true
    }

    static func sendLifecycle(pageId: String, state: String, reason: String) {
        guard let endpoint = endpoints[pageId] else { return }
        post(
            endpoint,
            eventName: lifecycleEvent,
            payload: [
                "pageId": endpoint.info.pageId,
                "containerId": endpoint.info.containerId,
                "pageKey": endpoint.info.pageKey,
                "hostMode": endpoint.info.hostMode,
                "state": state,
                "reason": reason,
                "timestampMillis": Date().timeIntervalSince1970 * 1000,
            ]
        )
    }

    private static func liveEndpoints() -> [Endpoint] {
        prune()
        return endpoints.values.filter { $0.view != nil }
    }

    private static func prune() {
        endpoints = endpoints.filter { $0.value.view != nil }
    }

    private static func post(
        _ endpoint: Endpoint,
        eventName: String,
        payload: [String: Any]
    ) {
        let deliver: () -> Void = { [weak endpoint] in
            guard let view = endpoint?.view else { return }
            view.sendGlobalEvent(eventName, withParams: [payload])
        }
        if Thread.isMainThread {
            deliver()
        } else {
            DispatchQueue.main.async(execute: deliver)
        }
    }

    private static func validateEventName(_ value: String, allowLifecycle: Bool) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 128 else {
            throw NSError(domain: "LynxRouter", code: 1001, userInfo: [
                NSLocalizedDescriptionKey: "eventName 不能为空且不能超过 128 个字符",
            ])
        }
        if !allowLifecycle && normalized == lifecycleEvent {
            throw NSError(domain: "LynxRouter", code: 1001, userInfo: [
                NSLocalizedDescriptionKey: "lynxRouterLifecycle 是宿主保留事件",
            ])
        }
    }
}
