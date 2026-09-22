#if DEBUG
import Foundation
import LynxShellKit

struct LynxDebugPageOption {
    let viewId: String
    let label: String
}

struct LynxDebugConsoleLog {
    let type: String
    let tag: String
    let message: String
    let viewId: String?
    let timestampMs: Int64
}

struct LynxDebugNetworkRequest {
    let id: String
    let viewId: String?
    let method: String
    let url: String
    let headers: [String: String]
    let bodyBytes: Int
    let body: String?
    let isStreaming: Bool
    let startTimeMs: Int64
    let endTimeMs: Int64?
    let statusCode: Int?
    let error: String?

    var curl: String {
        var command = "curl -X \(method) \(DebugRedactor.shellQuote(url))"
        headers.keys.sorted().forEach { key in
            command += " -H \(DebugRedactor.shellQuote("\(key): \(headers[key] ?? "")"))"
        }
        if let body {
            command += " --data-raw \(DebugRedactor.shellQuote(body))"
        } else if bodyBytes > 0 {
            command += " --data-binary \(DebugRedactor.shellQuote("<binary body redacted: \(bodyBytes) bytes>"))"
        }
        return command
    }
}

/** Debug-only bounded store。UI 只读取结构化快照，不直接展示原始 JSON。 */
public final class LynxDebugStore: LynxDebugSink {
    private struct Event {
        let event: LynxMonitorEvent
        let bytes: Int
        let viewId: String?
    }

    private let lock = NSLock()
    private var events: [Event] = []
    private var containers: [String: LynxDebugContainerSnapshot] = [:]
    private var consoleLogs: [LynxDebugConsoleLog] = []
    private var consoleRegistrations: [String: LynxDebugConsoleRegistration] = [:]
    private var methods: [LynxDebugMethodInvocation] = []
    private var networkRequests: [LynxDebugNetworkRequest] = []
    private var listeners: [UUID: () -> Void] = [:]
    private var bytes = 0
    private var discarded = 0

    public init() {}

    @discardableResult
    func addListener(_ listener: @escaping () -> Void) -> UUID {
        let id = UUID()
        lock.monitorLocked { listeners[id] = listener }
        return id
    }

    func removeListener(_ id: UUID) {
        _ = lock.monitorLocked { listeners.removeValue(forKey: id) }
    }

    public func attach(_ snapshot: LynxDebugContainerSnapshot) {
        lock.monitorLocked {
            containers[snapshot.viewId] = LynxDebugContainerSnapshot(
                viewId: snapshot.viewId,
                containerKind: snapshot.containerKind,
                visibility: snapshot.visibility,
                pageId: snapshot.pageId,
                routeKey: snapshot.routeKey,
                title: snapshot.title,
                bundleURL: DebugRedactor.url(snapshot.bundleURL),
                bundleMetadata: DebugRedactor.map(snapshot.bundleMetadata),
                globalProps: DebugRedactor.map(snapshot.globalProps),
                updatedAtMs: snapshot.updatedAtMs
            )
        }
        notifyChanged()
    }

    public func attachConsole(viewId: String, registration: LynxDebugConsoleRegistration) {
        let registered = registration.register { [weak self] raw in
            let parsed = Self.parseConsole(raw)
            self?.recordConsole(
                type: parsed.type,
                tag: parsed.tag,
                message: parsed.message,
                viewId: viewId
            )
        }
        guard registered else { return }
        lock.monitorLocked { consoleRegistrations[viewId] = registration }
    }

    public func updateVisibility(viewId: String, visibility: String) {
        lock.monitorLocked {
            guard let current = containers[viewId] else { return }
            containers[viewId] = LynxDebugContainerSnapshot(
                viewId: current.viewId,
                containerKind: current.containerKind,
                visibility: visibility,
                pageId: current.pageId,
                routeKey: current.routeKey,
                title: current.title,
                bundleURL: current.bundleURL,
                bundleMetadata: current.bundleMetadata,
                globalProps: current.globalProps,
                updatedAtMs: nowMs()
            )
        }
        notifyChanged()
    }

    public func updateGlobalProps(viewId: String, globalProps: [String: Any]) {
        lock.monitorLocked {
            guard let current = containers[viewId] else { return }
            containers[viewId] = LynxDebugContainerSnapshot(
                viewId: current.viewId,
                containerKind: current.containerKind,
                visibility: current.visibility,
                pageId: current.pageId,
                routeKey: current.routeKey,
                title: current.title,
                bundleURL: current.bundleURL,
                bundleMetadata: current.bundleMetadata,
                globalProps: DebugRedactor.map(globalProps),
                updatedAtMs: nowMs()
            )
        }
        notifyChanged()
    }

    public func record(_ event: LynxMonitorEvent) {
        lock.monitorLocked {
            guard let data = try? JSONEncoder().encode(event), data.count <= maxEventBytes else {
                discarded += 1
                return
            }
            while events.count >= maxEvents || bytes + data.count > maxBytes {
                bytes -= events.removeFirst().bytes
                discarded += 1
            }
            events.append(Event(event: event, bytes: data.count, viewId: event.viewId))
            bytes += data.count
        }
        notifyChanged()
    }

    public func recordMethod(_ invocation: LynxDebugMethodInvocation) {
        lock.monitorLocked {
            if methods.count >= maxMethods { methods.removeFirst() }
            methods.append(
                LynxDebugMethodInvocation(
                    name: invocation.name,
                    params: DebugRedactor.text(String(invocation.params.prefix(maxMethodTextLength))),
                    viewId: invocation.viewId,
                    startTimeMs: invocation.startTimeMs,
                    endTimeMs: invocation.endTimeMs,
                    code: invocation.code,
                    success: invocation.success,
                    result: invocation.result.map { DebugRedactor.text(String($0.prefix(maxMethodTextLength))) }
                )
            )
        }
        notifyChanged()
    }

    func recordConsole(type: String, tag: String, message: String, viewId: String?) {
        let timestamp = nowMs()
        lock.monitorLocked {
            let normalized = DebugRedactor.text(String(message.prefix(maxConsoleTextLength)))
            if let previous = consoleLogs.last,
               previous.type == type,
               previous.tag == tag,
               previous.message == normalized,
               timestamp - previous.timestampMs < 500 {
                return
            }
            if consoleLogs.count >= maxConsoleLogs { consoleLogs.removeFirst() }
            consoleLogs.append(
                LynxDebugConsoleLog(
                    type: type,
                    tag: tag,
                    message: normalized,
                    viewId: viewId,
                    timestampMs: timestamp
                )
            )
        }
        notifyChanged()
    }

    @discardableResult
    func beginNetwork(
        method: String,
        url: String,
        headers: [String: String],
        body: Data?,
        isStreaming: Bool,
        viewId: String?
    ) -> String {
        let id = UUID().uuidString
        let request = LynxDebugNetworkRequest(
            id: id,
            viewId: viewId,
            method: method.isEmpty ? "GET" : method.uppercased(),
            url: DebugRedactor.networkURL(url),
            headers: DebugRedactor.headers(headers),
            bodyBytes: body?.count ?? 0,
            body: DebugRedactor.body(body),
            isStreaming: isStreaming,
            startTimeMs: nowMs(),
            endTimeMs: nil,
            statusCode: nil,
            error: nil
        )
        lock.monitorLocked {
            if networkRequests.count >= maxNetworkRequests { networkRequests.removeFirst() }
            networkRequests.append(request)
        }
        notifyChanged()
        return id
    }

    func finishNetwork(id: String, statusCode: Int?, error: String?) {
        lock.monitorLocked {
            guard let index = networkRequests.firstIndex(where: { $0.id == id }) else { return }
            let current = networkRequests[index]
            networkRequests[index] = LynxDebugNetworkRequest(
                id: current.id,
                viewId: current.viewId,
                method: current.method,
                url: current.url,
                headers: current.headers,
                bodyBytes: current.bodyBytes,
                body: current.body,
                isStreaming: current.isStreaming,
                startTimeMs: current.startTimeMs,
                endTimeMs: nowMs(),
                statusCode: statusCode,
                error: error
            )
        }
        notifyChanged()
    }

    public func detach(viewId: String) {
        _ = lock.monitorLocked { containers.removeValue(forKey: viewId) }
        notifyChanged()
    }

    public func detachConsole(viewId: String) {
        let registration = lock.monitorLocked { consoleRegistrations.removeValue(forKey: viewId) }
        registration?.unregister()
    }

    func pageOptions() -> [LynxDebugPageOption] {
        lock.monitorLocked {
            containers.values.map { snapshot in
                LynxDebugPageOption(
                    viewId: snapshot.viewId,
                    label: "\(snapshot.containerKind) · \(snapshot.routeKey.isEmpty ? (snapshot.title.isEmpty ? String(snapshot.viewId.prefix(8)) : snapshot.title) : snapshot.routeKey)"
                )
            }
        }
    }

    func containers(for viewId: String?) -> [LynxDebugContainerSnapshot] {
        lock.monitorLocked { containers.values.filter { viewId == nil || $0.viewId == viewId } }
    }

    func console(for viewId: String?) -> [LynxDebugConsoleLog] {
        lock.monitorLocked { consoleLogs.filter { viewId == nil || $0.viewId == viewId } }
    }

    func methods(for viewId: String?) -> [LynxDebugMethodInvocation] {
        lock.monitorLocked { methods.filter { viewId == nil || $0.viewId == viewId } }
    }

    func network(for viewId: String?) -> [LynxDebugNetworkRequest] {
        lock.monitorLocked { networkRequests.filter { viewId == nil || $0.viewId == viewId } }
    }

    func networkAssociationViewId() -> String? {
        lock.monitorLocked {
            if containers.count == 1 { return containers.values.first?.viewId }
            return nil
        }
    }

    func clearConsole(viewId: String?) {
        lock.monitorLocked { consoleLogs.removeAll { viewId == nil || $0.viewId == viewId } }
        notifyChanged()
    }

    func clearNetwork(viewId: String?) {
        lock.monitorLocked { networkRequests.removeAll { viewId == nil || $0.viewId == viewId } }
        notifyChanged()
    }

    func clearMethods(viewId: String?) {
        lock.monitorLocked { methods.removeAll { viewId == nil || $0.viewId == viewId } }
        notifyChanged()
    }

    func clear(viewId: String? = nil) {
        lock.monitorLocked {
            guard let viewId else {
                events.removeAll()
                consoleLogs.removeAll()
                methods.removeAll()
                networkRequests.removeAll()
                bytes = 0
                discarded = 0
                return
            }
            events.removeAll { $0.viewId == viewId }
            consoleLogs.removeAll { $0.viewId == viewId }
            methods.removeAll { $0.viewId == viewId }
            networkRequests.removeAll { $0.viewId == viewId }
            bytes = events.reduce(0) { $0 + $1.bytes }
        }
        notifyChanged()
    }

    public func snapshotJSON() -> String {
        lock.monitorLocked {
            let containerPayload = containers.values.map { snapshot in
                [
                    "viewId": snapshot.viewId,
                    "containerKind": snapshot.containerKind,
                    "visibility": snapshot.visibility,
                    "pageId": snapshot.pageId,
                    "routeKey": snapshot.routeKey,
                    "title": snapshot.title,
                    "bundleURL": snapshot.bundleURL,
                    "bundleMetadata": snapshot.bundleMetadata,
                    "globalProps": snapshot.globalProps,
                    "updatedAtMs": snapshot.updatedAtMs,
                ] as [String: Any]
            }
            let eventPayload = events.compactMap { event -> Any? in
                guard let data = try? JSONEncoder().encode(event.event) else { return nil }
                return try? JSONSerialization.jsonObject(with: data)
            }
            let root: [String: Any] = [
                "schemaVersion": "1.0",
                "discarded": discarded,
                "containers": containerPayload,
                "events": eventPayload,
                "console": consoleLogs.map { log in
                    ["type": log.type, "tag": log.tag, "message": log.message, "viewId": log.viewId as Any, "timestampMs": log.timestampMs]
                },
                "network": networkRequests.map { request in
                    ["id": request.id, "viewId": request.viewId as Any, "method": request.method, "url": request.url, "curl": request.curl]
                },
                "methods": methods.map { method in
                    ["name": method.name, "params": method.params, "viewId": method.viewId as Any, "result": method.result as Any]
                },
            ]
            guard JSONSerialization.isValidJSONObject(root),
                  let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]),
                  let text = String(data: data, encoding: .utf8) else { return "{}" }
            return text
        }
    }

    private func notifyChanged() {
        let callbacks = lock.monitorLocked { Array(listeners.values) }
        guard !callbacks.isEmpty else { return }
        DispatchQueue.main.async { callbacks.forEach { $0() } }
    }

    private static func parseConsole(_ raw: String) -> (type: String, tag: String, message: String) {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return ("log", "console", raw)
        }
        let type = (dictionary["type"] as? String ?? "log").lowercased()
        let message: String
        if let values = dictionary["data"] as? [Any] {
            message = values.map { value in
                guard JSONSerialization.isValidJSONObject(value),
                      let data = try? JSONSerialization.data(withJSONObject: value),
                      let text = String(data: data, encoding: .utf8) else {
                    return String(describing: value)
                }
                return text
            }.joined(separator: "\t")
        } else {
            message = dictionary["message"] as? String ?? raw
        }
        return (type, "console", message)
    }

    private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private let maxEvents = 128
    private let maxBytes = 512 * 1024
    private let maxEventBytes = 32 * 1024
    private let maxConsoleLogs = 300
    private let maxConsoleTextLength = 16 * 1024
    private let maxMethods = 300
    private let maxMethodTextLength = 16 * 1024
    private let maxNetworkRequests = 200
}

private enum DebugRedactor {
    private static let sensitive = try! NSRegularExpression(
        pattern: "(?i)(token|secret|password|passwd|authorization|cookie|access[_-]?key|api[_-]?key|apikey|signature|credential|jwt|refresh[_-]?token|ticket|session)"
    )
    private static let sensitiveText = try! NSRegularExpression(
        pattern: "(?i)((?:token|secret|password|passwd|authorization|cookie|access[_-]?key|api[_-]?key|apikey|signature|credential|jwt|refresh[_-]?token|ticket|session)[\\\"'\\s:=]+)[^\\\"'\\s,;&}]+"
    )

    static func map(_ value: [String: Any], depth: Int = 0) -> [String: Any] {
        if depth >= 4 { return ["<truncated>": "max_depth"] }
        return Dictionary(uniqueKeysWithValues: value.prefix(128).map { key, value in
            let range = NSRange(location: 0, length: key.utf16.count)
            let redacted = sensitive.firstMatch(in: key, options: [], range: range) != nil
            return (key, redacted ? "<redacted>" : any(value, depth: depth + 1))
        })
    }

    static func url(_ value: String) -> String {
        guard var components = URLComponents(string: value) else {
            return value.split(separator: "?").first.map(String.init) ?? value
        }
        components.query = nil
        components.fragment = nil
        return components.string ?? value
    }

    static func networkURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else {
            return text(String(value.prefix(4096)))
        }
        components.fragment = nil
        components.queryItems = components.queryItems?.map { item in
            URLQueryItem(
                name: item.name,
                value: isSensitive(item.name) ? "<redacted>" : item.value.map(text)
            )
        }
        return components.string ?? text(String(value.prefix(4096)))
    }

    static func headers(_ value: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: value.prefix(128).map { key, item in
            (key, isSensitive(key) ? "<redacted>" : text(String(item.prefix(4096))))
        })
    }

    static func body(_ value: Data?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let bounded = Data(value.prefix(16 * 1024))
        if let object = try? JSONSerialization.jsonObject(with: bounded),
           JSONSerialization.isValidJSONObject(object) {
            let redacted = any(object, depth: 0)
            if let data = try? JSONSerialization.data(withJSONObject: redacted, options: [.sortedKeys]),
               let result = String(data: data, encoding: .utf8) {
                return result
            }
        }
        guard let result = String(data: bounded, encoding: .utf8) else { return nil }
        return text(result)
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func text(_ value: String) -> String {
        let range = NSRange(location: 0, length: value.utf16.count)
        return sensitiveText.stringByReplacingMatches(
            in: value,
            options: [],
            range: range,
            withTemplate: "$1<redacted>"
        )
    }

    private static func isSensitive(_ key: String) -> Bool {
        let range = NSRange(location: 0, length: key.utf16.count)
        return sensitive.firstMatch(in: key, options: [], range: range) != nil
    }

    private static func any(_ value: Any, depth: Int) -> Any {
        if let value = value as? String {
            let bounded = value.count > 4096 ? String(value.prefix(4096)) + "<truncated>" : value
            return text(bounded)
        }
        if let value = value as? [String: Any] { return map(value, depth: depth) }
        if let value = value as? [Any] { return value.prefix(128).map { any($0, depth: depth) } }
        if value is NSNull || value is NSNumber { return value }
        return String(String(describing: value).prefix(1024))
    }
}

private extension NSLock {
    func monitorLocked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
#endif
