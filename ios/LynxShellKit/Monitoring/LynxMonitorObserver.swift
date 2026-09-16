import CoreFoundation
import Foundation
import Lynx

/** 仅观察，不修改原有首屏、错误页、转场或 OTA 恢复决策。 */
final class LynxMonitorObserver: NSObject, LynxViewLifecycle, LynxViewLifecycleV2 {
    private let scope: LynxMonitorScope
    init(scope: LynxMonitorScope) {
        self.scope = scope
        super.init()
    }

    func onPageStarted(with view: LynxView, with info: LynxPipelineInfo) {
        scope.pageStarted(isReload: (info.pipelineOrigin & 2) != 0)
    }

    func lynxViewDidFirstScreen(_ view: LynxView) { scope.didFirstContent() }

    func lynxView(_ view: LynxView, didLoadFinishedWithUrl url: String) { scope.didLoad() }

    func receivedError(_ error: Error) {
        guard let error = error as? LynxError else {
            scope.record(.diagnostic(code: "non_lynx_error", count: 1, detail: nil))
            return
        }
        let code = error.errorCode
        // 使用 4.1 LynxError.isJSError / isLepusError 的公开分类区间，不将所有原生错误当 JS 异常。
        let background = (200 ..< 300).contains(code)
        let mainThread = (1100 ..< 1200).contains(code)
        guard background || mainThread else {
            scope.record(.diagnostic(code: "non_js_lynx_error", count: 1, detail: String(code)))
            return
        }
        let message = error.summaryMessage
        // 官方头文件将可选 callStack 标为 nonnull，固定 KVC 键避免 nil 跨接为 String 时崩溃。
        let raw = error.value(forKey: #keyPath(LynxError.callStack)) as? String
        let stack = raw.flatMap { $0.isEmpty ? nil : $0 }
        var truncated: [String] = []
        if message.utf8.count > 4 * 1024 { truncated.append("message") }
        if let stack, stack.utf8.count > 16 * 1024 { truncated.append("rawStack") }
        let level = error.isFatal ? "fatal" : (error.level == "warn" ? "warning" : (error.level == "error" ? "error" : "unknown"))
        // LynxError 不可跨线程共享，只把允许字段复制成 Swift 值。
        scope.jsError(code: String(code), subCode: String(error.getSubCode()), level: level,
                      realm: background ? "background" : "main_thread",
                      message: LynxMonitorSanitizer.bounded(message, bytes: 4 * 1024),
                      stack: stack.map { LynxMonitorSanitizer.bounded($0, bytes: 16 * 1024) }, truncated: truncated)
    }

    func onResourceLoaded(_ result: LynxResourceLoadInfo) {
        scope.record(.resource(resourceType: String(result.type.rawValue), failed: result.errCode != 0,
                               errorCode: result.errCode == 0 ? nil : String(result.errCode)))
    }

    func onPerformanceEvent(_ entry: LynxPerformanceEntry) {
        let name = entry.name
        let type = entry.entryType
        let pipelineNames: Set<String> = ["loadBundle", "reloadBundleFromNative", "reloadBundleFromBts",
                                          "updateTriggeredByBts", "updateTriggeredByNative", "reactLynxHydrate",
                                          "updateGlobalProps", "setNativeProps"]
        guard (type == "pipeline" && pipelineNames.contains(name)) || (type == "resource" && name == "lazyBundle") else { return }
        let raw = entry.rawDictionary as NSDictionary
        var missing: [String] = []
        var invalid: [String] = []
        var timing: [String: Double] = [:]
        var metrics: [LynxMonitorMetric] = []
        var truncated: [String] = []
        func number(_ value: Any?, path: String) -> Double? {
            guard let value else { missing.append(path); return nil }
            let result: Double?
            if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { result = n.doubleValue }
            else if let text = value as? String { result = Double(text) }
            else { result = nil }
            guard let result, result.isFinite, result >= 0 else { invalid.append(path); return nil }
            return result
        }
        let commonTimings = ["pipelineStart", "pipelineEnd", "mtsRenderStart", "mtsRenderEnd", "resolveStart", "resolveEnd",
                             "layoutStart", "layoutEnd", "paintingUiOperationExecuteStart", "paintingUiOperationExecuteEnd",
                             "layoutUiOperationExecuteStart", "layoutUiOperationExecuteEnd", "paintEnd"]
        let loadTimings = ["loadBundleStart", "loadBundleEnd", "parseStart", "parseEnd", "loadBackgroundStart", "loadBackgroundEnd"]
        let reloadTimings = ["reloadBundleStart", "reloadBundleEnd", "reloadBackgroundStart", "reloadBackgroundEnd"]
        let lifecycleTimings = ["createLynxStart", "createLynxEnd", "loadCoreStart", "loadCoreEnd", "openTime",
                                "containerInitStart", "containerInitEnd", "prepareTemplateStart", "prepareTemplateEnd"]
        let fields = name == "lazyBundle" ? ["requireStart", "requireEnd", "decodeStart", "decodeEnd"] :
            commonTimings + (name == "loadBundle" ? loadTimings + lifecycleTimings :
                (name.hasPrefix("reloadBundle") ? reloadTimings + lifecycleTimings : []))
        for field in fields {
            if let value = number(raw[field], path: field) { timing[field] = value }
        }
        func difference(_ metric: String, _ start: String, _ end: String) {
            guard let from = timing[start], let to = timing[end] else { return }
            guard to >= from else { invalid.append("\(end)<\(start)"); return }
            metrics.append(.init(name: metric, value: to - from, origin: .sdkDifference, sourceFields: [start, end]))
        }
        if type == "pipeline" {
            for (metric, start, end) in [
                ("mts_render_ms", "mtsRenderStart", "mtsRenderEnd"),
                ("style_resolve_ms", "resolveStart", "resolveEnd"),
                ("layout_ms", "layoutStart", "layoutEnd"),
                ("paint_ui_ops_ms", "paintingUiOperationExecuteStart", "paintingUiOperationExecuteEnd"),
                ("pipeline_ms", "pipelineStart", "pipelineEnd")
            ] { difference(metric, start, end) }
        }
        if name == "loadBundle" {
            difference("parse_ms", "parseStart", "parseEnd")
            difference("bts_load_ms", "loadBackgroundStart", "loadBackgroundEnd")
        }
        if name == "loadBundle" || name.hasPrefix("reloadBundle") {
            for (metric, field) in [("lynx_fcp_ms", "lynxFcp"), ("prepare_to_fcp_ms", "fcp"), ("open_to_fcp_ms", "totalFcp")] {
                guard let value = raw[field] as? NSDictionary else { missing.append(field); continue }
                guard let duration = number(value["duration"], path: "\(field).duration") else { continue }
                metrics.append(.init(name: metric, value: duration, origin: .sdkDuration, sourceFields: ["\(field).duration"]))
            }
        }
        for field in ["actualFmp", "lynxActualFmp", "totalActualFmp"] {
            guard let value = raw[field] as? NSDictionary else { continue }
            for key in ["duration", "startTimestamp", "endTimestamp"] {
                if let n = number(value[key], path: "\(field).\(key)") { timing["\(field).\(key)"] = n }
            }
        }
        let identifier = raw["identifier"] as? String
        if let identifier, identifier.utf8.count > 256 { truncated.append("identifier") }
        scope.performance(.init(entryType: type, entryName: name,
                                identifier: identifier.map { LynxMonitorSanitizer.bounded($0, bytes: 256) },
                                metrics: metrics, timing: timing), missing: missing, invalid: invalid, truncated: truncated)
    }
}
