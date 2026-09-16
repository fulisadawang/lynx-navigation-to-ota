import Foundation

enum LynxMonitorSanitizer {
    private static let secret = try! NSRegularExpression(
        pattern: "(?i)\\b(authorization|access[_-]?token|refresh[_-]?token|token|password|secret|accesskey)\\s*[:=]\\s*(?:(?:bearer|basic)\\s+)?([^\\s,;]+)"
    )
    private static let cookie = try! NSRegularExpression(pattern: "(?im)\\b(cookie|set-cookie)\\s*[:=][^\\r\\n]*")
    private static let remoteURL = try! NSRegularExpression(pattern: "https?://[^\\s)]+")
    private static let debugKey = try! NSRegularExpression(pattern: "debugmetadata:([^\\s:()]+)")
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
        guard case let .jsError(error) = event.payload else { return event }
        func clean(_ value: String, limit: Int) -> (text: String, truncated: Bool) {
            let safe = redact(value)
            let redacted = customRedactor?(safe) ?? safe
            return (bounded(redacted, bytes: limit), redacted.utf8.count > limit)
        }
        let cleanedMessage = clean(error.message, limit: 4 * 1024)
        let cleanedStack = error.rawStack.map { clean($0, limit: 16 * 1024) }
        let message = cleanedMessage.text
        let stack = cleanedStack?.text
        let frames = stack.map(parseFrames) ?? []
        var missing = event.quality.missingFields
        if frames.isEmpty, !missing.contains("frames") { missing.append("frames") }
        var truncated = event.quality.truncatedFields
        if cleanedMessage.truncated, !truncated.contains("message") { truncated.append("message") }
        if cleanedStack?.truncated == true, !truncated.contains("rawStack") { truncated.append("rawStack") }
        if (stack?.split(separator: "\n").count ?? 0) > 64 { truncated.append("frames") }
        let result = LynxMonitorJSError(errorCode: error.errorCode, subCode: error.subCode, level: error.level,
                                       realm: error.realm, message: message, rawStack: stack, frames: frames,
                                       handled: error.handled, phase: error.phase)
        return event.replacing(payload: .jsError(result), missing: missing, truncated: truncated)
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
                      let line = Int(pair[1]), let column = Int(pair[2]), line > 0, column >= 0 {
                // 后台脚本的常见 file:line:column 格式可直接交给 Source Map；主线程数字含义仍保持未知。
                position = pair[0].contains("main-thread.js")
                    ? .unknown
                    : .lineColumn(line: line, column: column)
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
    func replacing(payload: LynxMonitorPayload, missing: [String], truncated: [String]) -> LynxMonitorEvent {
        .init(eventId: eventId, processSessionId: processSessionId, observedAtMs: observedAtMs,
              runtimeVersion: runtimeVersion, hostBuild: hostBuild, viewId: viewId, nativeInstanceId: nativeInstanceId,
              containerKind: containerKind, loadId: loadId, loadKind: loadKind, bundle: bundle, visibility: visibility,
              quality: .init(association: quality.association, late: quality.late, missingFields: missing,
                             invalidFields: quality.invalidFields, truncatedFields: truncated), sampling: sampling, payload: payload)
    }

    /** 计算 JSON 字符串转义后的上界；固定结构另预留空间，入队前不做 JSON 编码。 */
    var monitorBudgetBytes: Int {
        func stringBytes(_ value: String?) -> Int {
            guard let value else { return 4 }
            return value.utf8.reduce(2) { count, byte in
                count + (byte < 0x20 ? 6 : (byte == 0x22 || byte == 0x5c || byte == 0x2f ? 2 : 1))
            }
        }
        var strings = [eventId, processSessionId, runtimeVersion, hostBuild, viewId, nativeInstanceId, loadId]
        if let bundle {
            strings += [bundle.lynxAppId, bundle.bundleName, bundle.releaseId, bundle.releaseSequence, bundle.sha256, bundle.missingReason, bundle.buildId]
        }
        strings += quality.missingFields.map(Optional.some) + quality.invalidFields.map(Optional.some) + quality.truncatedFields.map(Optional.some)
        var fixed = 2048
        switch payload {
        case let .jsError(error):
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
        case .lifecycle: break
        }
        return strings.reduce(fixed) { $0 + stringBytes($1) }
    }
}
