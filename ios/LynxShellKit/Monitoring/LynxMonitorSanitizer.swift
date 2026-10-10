import CoreFoundation
import Foundation

enum LynxMonitorSanitizer {
    private static let secret = try! NSRegularExpression(
        pattern: "(?i)\\b(authorization|access[_-]?token|refresh[_-]?token|token|password|secret|accesskey)\\s*[:=]\\s*(?:(?:bearer|basic)\\s+)?([^\\s,;]+)"
    )
    private static let cookie = try! NSRegularExpression(pattern: "(?im)\\b(cookie|set-cookie)\\s*[:=][^\\r\\n]*")
    private static let remoteURL = try! NSRegularExpression(pattern: "https?://[^\\s)]+")
    private static let debugKey = try! NSRegularExpression(pattern: "debugmetadata:([^\\s:()]+)")
    private static let validDebugRelease = try! NSRegularExpression(pattern: "^debugmetadata:[A-Za-z0-9._/-]+$")
    private static let explicitPC = try! NSRegularExpression(pattern: "function[_-]?id\\s*[:=]\\s*(\\d+)\\s*[,; ]+pc(?:[_-]?index)?\\s*[:=]\\s*(\\d+)", options: .caseInsensitive)
    private static let explicitLine = try! NSRegularExpression(pattern: "line\\s*[:=]\\s*(\\d+)\\s*[,; ]+column\\s*[:=]\\s*(\\d+)", options: .caseInsensitive)
    private static let location = try! NSRegularExpression(
        pattern: "(?:\\(|@|\\s)((?:file://|https?://|/)?[^\\s()]+?):([0-9]+):([0-9]+)\\)?"
    )

    static func bounded(_ value: String, bytes: Int) -> String {
        guard value.utf8.count > bytes else { return value }
        var prefix = Array(value.utf8.prefix(bytes))
        while let last = prefix.last {
            if let result = String(bytes: prefix, encoding: .utf8) { return result }
            prefix.removeLast()
            if last < 0x80 { break }
        }
        return String(bytes: prefix, encoding: .utf8) ?? ""
    }

    static func process(_ event: LynxMonitorEvent, customRedactor: ((String) -> String)?) -> LynxMonitorEvent {
        if case let .business(business) = event.payload {
            guard let customRedactor else { return event }
            // 内建清理已在入队前完成；宿主回调只在串行交付线程补充执行。
            let attributes = business.attributes.mapValues { value -> LynxMonitorBusinessValue in
                if case let .string(text) = value { return .string(customRedactor(text)) }
                return value
            }
            return event.replacing(payload: .business(.init(group: business.group, name: business.name, attributes: attributes)),
                                   missing: event.quality.missingFields, truncated: event.quality.truncatedFields)
        }
        guard case let .jsError(error) = event.payload else { return event }
        func clean(_ value: String, limit: Int) -> (text: String, truncated: Bool) {
            let safe = redact(value)
            let redacted = customRedactor?(safe) ?? safe
            return (bounded(redacted, bytes: limit), redacted.utf8.count > limit)
        }
        let projected = error.sdkErrorJSON.flatMap(projectSDKError)
        let cleanedMessage = clean(projected?.message ?? error.message, limit: 4 * 1024)
        let cleanedStack = (projected?.stack ?? error.rawStack).map { clean($0, limit: 16 * 1024) }
        let message = cleanedMessage.text
        let stack = cleanedStack?.text
        let reportedFrames: [LynxMonitorErrorFrame]
        if let projected, !projected.frames.isEmpty {
            reportedFrames = projected.frames
        } else {
            reportedFrames = stack.map(parseFrames) ?? []
        }
        var missing = Set(event.quality.missingFields)
        var invalid = Set(event.quality.invalidFields)
        var truncated = Set(event.quality.truncatedFields + (projected?.truncated ?? []))
        if truncated.remove("sdkCallStack") != nil, projected?.stack == nil {
            truncated.insert("rawStack")
        }
        let frames = reportedFrames.map { frame -> LynxMonitorErrorFrame in
            let release = frame.runtimeRelease.flatMap { value -> String? in
                guard value.utf8.count <= 512,
                      let match = validDebugRelease.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                      match.range.length == value.utf16.count else {
                    invalid.insert("frames.runtimeRelease")
                    if value.utf8.count > 512 { truncated.insert("frames.runtimeRelease") }
                    return nil
                }
                return value
            }
            let file = frame.file.map { clean($0, limit: 512) }
            let function = frame.functionName.map { clean($0, limit: 256) }
            if file?.truncated == true { truncated.insert("frames.file") }
            if function?.truncated == true { truncated.insert("frames.functionName") }
            return .init(file: file?.text, functionName: function?.text,
                         runtimeRelease: release,
                         debugKey: release.map { String($0.dropFirst("debugmetadata:".count)) }, position: frame.position)
        }
        if error.sdkErrorJSON != nil && projected == nil { missing.formUnion(["structuredError", "message"]) }
        if message.isEmpty { missing.insert("message") }
        if stack == nil { missing.insert("rawStack") }
        if frames.isEmpty { missing.insert("frames") }
        if frames.contains(where: { $0.debugKey == nil }) { missing.insert("frames.debugKey") }
        if frames.contains(where: { if case .unknown = $0.position { return true }; return false }) {
            missing.insert("frames.positionKind")
        }
        if cleanedMessage.truncated { truncated.insert("message") }
        if cleanedStack?.truncated == true { truncated.insert("rawStack") }
        if (stack?.split(separator: "\n").count ?? 0) > 64 { truncated.insert("frames") }
        let result = LynxMonitorJSError(errorCode: error.errorCode, subCode: error.subCode, level: error.level,
                                       realm: error.realm, message: message, rawStack: stack, frames: frames,
                                       handled: error.handled, phase: error.phase, sdkErrorJSON: nil)
        return event.replacing(payload: .jsError(result), missing: missing.sorted(), truncated: truncated.sorted(), invalid: invalid.sorted())
    }

    private struct SDKProjection {
        let message: String
        let stack: String?
        let frames: [LynxMonitorErrorFrame]
        let truncated: [String]
    }

    /** 仅投影 4.1 JSErrorReporter 的公开实际格式，SDK 对象和任意 customInfo 不进入 Provider。 */
    private static func projectSDKError(_ text: String) -> SDKProjection? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let raw = root["rawError"] as? [String: Any], let message = raw["message"] as? String else { return nil }
        let stack = (raw["stack"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let sentry = root["sentry"] as? [String: Any]
        let exception = sentry?["exception"] as? [String: Any]
        let values = exception?["values"] as? [[String: Any]]
        let stacktrace = values?.first?["stacktrace"] as? [String: Any]
        let reported = stacktrace?["frames"] as? [[String: Any]] ?? []
        var truncated: Set<String> = []
        if reported.count > 64 { truncated.insert("frames") }
        func string(_ value: Any?, field: String, limit: Int) -> String? {
            guard let text = value as? String, !text.isEmpty else { return nil }
            if text.utf8.count > limit { truncated.insert(field) }
            return bounded(text, bytes: limit)
        }
        func number(_ value: Any?) -> Int? {
            guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  let result = Int(exactly: value.doubleValue), result >= 0 else { return nil }
            return result
        }
        let frames = reported.prefix(64).map { frame -> LynxMonitorErrorFrame in
            let rawRelease = frame["release"] as? String
            let release = rawRelease.flatMap { $0.isEmpty ? nil : $0 }
            let position: LynxMonitorErrorFrame.Position
            if let first = number(frame["lineno"]), let second = number(frame["colno"]) {
                position = .reported(first: first, second: second)
            } else {
                position = .unknown
            }
            return .init(file: string(frame["filename"], field: "frames.file", limit: 512),
                         functionName: string(frame["function"], field: "frames.functionName", limit: 256),
                         runtimeRelease: release, debugKey: nil, position: position)
        }
        return .init(message: message, stack: stack, frames: frames, truncated: truncated.sorted())
    }

    static func sanitizeBusiness(_ value: LynxMonitorBusinessEvent) -> LynxMonitorBusinessEvent {
        let attributes = value.attributes.mapValues { attribute -> LynxMonitorBusinessValue in
            if case let .string(text) = attribute { return .string(redact(text)) }
            return attribute
        }
        return .init(group: value.group, name: value.name, attributes: attributes)
    }

    private static func redact(_ text: String) -> String {
        var result = secret.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1=[redacted]")
        result = cookie.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1=[redacted]")
        for match in remoteURL.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let url = String(result[range])
            if var components = URLComponents(string: url) {
                components.query = nil
                components.fragment = nil
                components.user = nil
                components.password = nil
                result.replaceSubrange(range, with: components.string ?? "[url]")
            } else {
                result.replaceSubrange(range, with: "[url]")
            }
        }
        return result
    }

    private static func parseFrames(_ stack: String) -> [LynxMonitorErrorFrame] {
        stack.split(separator: "\n").prefix(64).compactMap { line in
            let text = String(line).trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("at ") || text.contains("@") || text.contains("debugmetadata:") || text.contains("function_id") else { return nil }
            func captures(_ regex: NSRegularExpression) -> [String]? {
                guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
                return (1 ..< match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
            }
            let key = captures(debugKey)?.first
            let position: LynxMonitorErrorFrame.Position
            if let pair = captures(explicitPC), pair.count == 2, let id = Int(pair[0]), let pc = Int(pair[1]) {
                position = .functionPC(functionId: id, pc: pc)
            } else if let pair = captures(explicitLine), pair.count == 2, let line = Int(pair[0]), let column = Int(pair[1]),
                      line > 0, column >= 0 {
                position = .lineColumn(line: line, column: column)
            } else if let pair = captures(location), pair.count == 3,
                      let first = Int(pair[1]), let second = Int(pair[2]), first >= 0, second >= 0 {
                position = .reported(first: first, second: second)
            } else {
                // 裸数字对的编译格式必须由产物清单证明，采集端不按文件名或线程猜测。
                position = .unknown
            }
            let file: String?
            let name: String?
            if let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close {
                file = bounded(String(text[text.index(after: open) ..< close]), bytes: 512)
                name = bounded(String(text[..<open]).replacingOccurrences(of: "at ", with: "").trimmingCharacters(in: .whitespaces), bytes: 256)
            } else {
                let location = text.replacingOccurrences(of: "at ", with: "").trimmingCharacters(in: .whitespaces)
                file = bounded(location, bytes: 512)
                name = nil
            }
            return LynxMonitorErrorFrame(file: file, functionName: name,
                                         runtimeRelease: key.map { "debugmetadata:\($0)" }, debugKey: key, position: position)
        }
    }

}

extension LynxMonitorEvent {
    func replacing(payload: LynxMonitorPayload, missing: [String], truncated: [String], invalid: [String]? = nil) -> LynxMonitorEvent {
        .init(eventId: eventId, processSessionId: processSessionId, observedAtMs: observedAtMs,
              runtimeVersion: runtimeVersion, hostBuild: hostBuild, viewId: viewId, nativeInstanceId: nativeInstanceId,
              containerKind: containerKind, loadId: loadId, loadKind: loadKind, bundle: bundle, visibility: visibility,
              quality: .init(association: quality.association, late: quality.late, missingFields: missing,
                             invalidFields: invalid ?? quality.invalidFields, truncatedFields: truncated), sampling: sampling, payload: payload)
    }

    /** 计算 JSON 字符串转义后的上界；固定结构另预留空间，入队前不做 JSON 编码。 */
    var monitorBudgetBytes: Int {
        func stringBytes(_ value: String?) -> Int {
            guard let value else { return 4 }
            return value.utf8.reduce(2) { count, byte in
                count + (byte < 0x20 ? 6 : (byte == 0x22 || byte == 0x5c || byte == 0x2f ? 2 : 1))
            }
        }
        var strings = [group, eventId, processSessionId, runtimeVersion, hostBuild, viewId, nativeInstanceId, loadId]
        if let bundle {
            strings += [bundle.env, bundle.hostApp, bundle.lynxAppId, bundle.bundleName, bundle.bundlePath, bundle.releaseId, bundle.releaseSequence, bundle.sha256, bundle.missingReason, bundle.buildId]
        }
        strings += quality.missingFields.map(Optional.some) + quality.invalidFields.map(Optional.some) + quality.truncatedFields.map(Optional.some)
        var fixed = 2048
        switch payload {
        case let .jsError(error):
            // 内部 SDK JSON 不编码，但排队期间仍占用内存预算。
            fixed += error.sdkErrorJSON?.utf8.count ?? 0
            strings += [error.errorCode, error.subCode, error.message, error.rawStack]
            for frame in error.frames {
                strings += [frame.file, frame.functionName, frame.runtimeRelease, frame.debugKey]
                fixed += 192
            }
        case let .performance(performance):
            strings += [performance.entryType, performance.entryName, performance.identifier]
            strings += performance.timing.keys.map(Optional.some)
            fixed += performance.timing.count * 32
            for metric in performance.metrics {
                strings += [metric.name] + metric.sourceFields.map(Optional.some)
                fixed += 192
            }
        case let .load(_, reason, _): strings += [reason]
        case let .resource(type, _, code): strings += [type, code]
        case let .diagnostic(code, _, detail): strings += [code, detail]
        case let .business(business):
            strings.append(business.name)
            for (key, value) in business.attributes {
                strings.append(key)
                fixed += 2 // 每项的冒号和逗号；引号已计入 stringBytes。
                switch value {
                case let .string(text): strings.append(text)
                case .number: fixed += 32 // 有限 Double 的 JSON 数字表示上界。
                case .boolean: fixed += 5
                }
            }
        case .lifecycle: break
        }
        return strings.reduce(fixed) { $0 + stringBytes($1) }
    }
}
