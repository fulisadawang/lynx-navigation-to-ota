import CryptoKit
import Foundation
import UIKit

/** 生命周期和关联状态只在本实例内变更；事件生成后是不可变快照。 */
final class LynxMonitorScope {
    let viewId = UUID().uuidString
    private let runtime: LynxMonitorRuntime
    private let kind: LynxMonitorContainerKind
    private let lock = NSLock()
    private var loadId = UUID().uuidString
    private var loadKind: LynxMonitorLoadKind
    private var visibility: LynxMonitorVisibility
    private var backgrounded: Bool
    private var closed = false
    private var created = false
    private var terminalLoad = false
    private var firstContent = false
    private var loaded = false
    private var pageStarts = 0
    private var ambiguous = false
    private var bundle: LynxMonitorBundleIdentity?
    private var expectedSHA: String?
    private var boundBytes = false
    private var metricNames: Set<String> = []
    private let sampled: Bool
    private var notifications: [NSObjectProtocol] = []

    init(runtime: LynxMonitorRuntime, kind: LynxMonitorContainerKind, loadKind: LynxMonitorLoadKind,
         visibility: LynxMonitorVisibility) {
        self.runtime = runtime
        self.kind = kind
        self.loadKind = loadKind
        self.visibility = visibility
        self.backgrounded = UIApplication.shared.applicationState == .background
        var hash: UInt64 = 14695981039346656037
        for byte in viewId.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        self.sampled = runtime.capabilities.samplingOwner == .provider ||
            (runtime.sampleRate > 0 && Double(hash >> 11) / 9007199254740992 < runtime.sampleRate)
        notifications = [
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setBackground(true)
            },
            NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setBackground(false)
            }
        ]
        record(.load(phase: .started, reasonCode: nil, durationMs: nil))
    }

    deinit { notifications.forEach(NotificationCenter.default.removeObserver) }

    func setRequest(source: LynxMonitorBundleSource, appId: String?, bundleName: String?) {
        lock.monitorLocked {
            guard !closed, !boundBytes else { return }
            bundle = .init(source: source, lynxAppId: appId, bundleName: bundleName, releaseId: nil,
                           releaseSequence: nil, sha256: nil, identityStatus: .unavailable,
                           missingReason: "bytes_not_resolved", buildId: nil)
        }
    }

    func setPreparedBundle(_ prepared: PreparedOtaBundle) {
        lock.monitorLocked {
            guard !closed, !boundBytes else { return }
            bundle = .init(source: prepared.source == "embedded_baseline" ? .embedded : .ota,
                           lynxAppId: prepared.lynxAppId, bundleName: prepared.bundleName,
                           releaseId: prepared.releaseId, releaseSequence: prepared.releaseSequence,
                           sha256: nil, identityStatus: .unavailable, missingReason: "bytes_not_resolved", buildId: nil)
            expectedSHA = prepared.releaseLease?.bundle.bundleSha256
                .lowercased().replacingOccurrences(of: "sha256:", with: "")
        }
    }

    /** 由 TemplateProvider 的读取线程调用，哈希始终对应本次返回给 Lynx 的 Data。 */
    func resolved(_ data: Data) {
        guard lock.monitorLocked({ !closed && !boundBytes }) else { return }
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        lock.lock()
        defer { lock.unlock() }
        guard !closed, !boundBytes, let original = bundle else { return }
        let matches = expectedSHA.map { $0 == sha }
        boundBytes = true
        bundle = .init(source: original.source, lynxAppId: original.lynxAppId, bundleName: original.bundleName,
                       releaseId: matches == false ? nil : original.releaseId,
                       releaseSequence: matches == false ? nil : original.releaseSequence,
                       sha256: sha, identityStatus: matches == true ? .verified : .computed,
                       // computed 也代表当前字节已有可用 SHA；预期 SHA 不匹配通过诊断计数披露，
                       // 不把 missingReason 填进一个已经有 SHA 的 BundleIdentity。
                       missingReason: nil, buildId: nil)
        if matches == false { runtime.counts("prepared_hash_mismatch") }
        // 当前交付回调包含 View 创建阶段，不将该混合区间冒充纯 Bundle 准备耗时。
        emitLocked(.load(phase: .resolved, reasonCode: nil, durationMs: nil), missing: ["bundle_prepare_ms"])
    }

    func didCreate(durationMs: Double) {
        lock.monitorLocked {
            guard !closed, !created else { return }
            created = true
            emitLocked(.lifecycle(state: .created, durationMs: durationMs))
        }
    }

    func pageStarted(isReload: Bool) {
        lock.monitorLocked {
            guard !closed else { runtime.counts("late_callback_dropped"); return }
            pageStarts += 1
            guard isReload || pageStarts > 1 else { return }
            if !terminalLoad {
                emitLocked(.load(phase: .incomplete, reasonCode: "same_view_reload", durationMs: nil))
            }
            loadId = UUID().uuidString
            loadKind = .reload
            ambiguous = true
            terminalLoad = false
            firstContent = false
            loaded = false
            emitLocked(.load(phase: .started, reasonCode: "ambiguous_load", durationMs: nil))
            runtime.counts("ambiguous_load")
        }
    }

    func didLoad() {
        lock.monitorLocked {
            guard !closed, !loaded, !terminalLoad else { return }
            loaded = true
            emitLocked(.load(phase: .loadedUnconfirmed, reasonCode: nil, durationMs: nil))
        }
    }

    func didFirstContent() {
        lock.monitorLocked { firstContentLocked() }
    }

    private func firstContentLocked() {
        guard !closed, !terminalLoad, !ambiguous else { return }
        firstContent = true
        terminalLoad = true
        emitLocked(.load(phase: .firstContent, reasonCode: nil, durationMs: nil))
    }

    func failed(reason: String) {
        lock.monitorLocked {
            guard !closed, !terminalLoad else { return }
            terminalLoad = true
            emitLocked(.load(phase: .failed, reasonCode: reason, durationMs: nil))
        }
    }

    func setVisibility(_ value: LynxMonitorVisibility) {
        lock.monitorLocked {
            guard !closed, visibility != value else { return }
            visibility = value
            guard created, !backgrounded else { return }
            emitLocked(.lifecycle(state: value == .visible ? .visible : .hidden, durationMs: nil))
        }
    }

    private func setBackground(_ value: Bool) {
        lock.monitorLocked {
            guard !closed, backgrounded != value else { return }
            backgrounded = value
            guard created else { return }
            let state: LynxMonitorPayload.LifecycleState = value ? .background : (visibility == .visible ? .visible : .hidden)
            emitLocked(.lifecycle(state: state, durationMs: nil))
        }
    }

    func close(reason: String) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        if !terminalLoad {
            terminalLoad = true
            emitLocked(.load(phase: .cancelled, reasonCode: reason, durationMs: nil))
        }
        if created { emitLocked(.lifecycle(state: .destroyed, durationMs: nil)) }
        closed = true
        let tokens = notifications
        notifications.removeAll()
        lock.unlock()
        tokens.forEach(NotificationCenter.default.removeObserver)
    }

    func performance(_ value: LynxMonitorPerformance, missing: [String], invalid: [String], truncated: [String]) {
        lock.monitorLocked {
            guard !closed else { runtime.counts("late_callback_dropped"); return }
            if value.metrics.contains(where: { $0.name == "lynx_fcp_ms" }) { firstContentLocked() }
            guard sampled else { runtime.counts("performance_sampled_out"); return }
            let metrics = value.metrics.filter { metric in
                guard ["lynx_fcp_ms", "prepare_to_fcp_ms", "open_to_fcp_ms"].contains(metric.name) else { return true }
                return metricNames.insert(metric.name).inserted
            }
            let accepted = LynxMonitorPerformance(entryType: value.entryType, entryName: value.entryName,
                                                  identifier: value.identifier, metrics: metrics, timing: value.timing)
            emitLocked(.performance(accepted), missing: missing, invalid: invalid, truncated: truncated)
        }
    }

    func jsError(code: String, subCode: String, level: String, realm: String, message: String, stack: String?, truncated: [String]) {
        lock.monitorLocked {
            guard !closed else { runtime.counts("late_callback_dropped"); return }
            let value = LynxMonitorJSError(errorCode: code, subCode: subCode, level: level, realm: realm,
                                           message: message, rawStack: stack, frames: [], handled: "unknown",
                                           phase: ambiguous ? "unknown" : (firstContent ? "running" : "loading"))
            emitLocked(.jsError(value),
                       missing: stack == nil ? ["rawStack"] : [],
                       truncated: truncated)
        }
    }

    func record(_ payload: LynxMonitorPayload) {
        lock.monitorLocked {
            guard !closed else { runtime.counts("late_callback_dropped"); return }
            emitLocked(payload)
        }
    }

    private func emitLocked(_ payload: LynxMonitorPayload, missing: [String] = [], invalid: [String] = [], truncated: [String] = []) {
        let performance = payload.eventType == .performance
        let sampling: LynxMonitorSampling = performance
            ? .init(owner: runtime.capabilities.samplingOwner,
                    rate: runtime.capabilities.samplingOwner == .provider ? nil : runtime.sampleRate)
            : .init(owner: .none, rate: 1)
        let hasBundle = bundle != nil
        let exactLoad = !ambiguous && hasBundle
        let quality = LynxMonitorQuality(association: exactLoad ? .exactLoad : .exactView, late: false,
                                         missingFields: missing
                                            + (ambiguous ? ["ambiguous_load"] : [])
                                            + (!hasBundle ? ["bundle"] : []),
                                         invalidFields: invalid, truncatedFields: truncated)
        runtime.enqueue(.init(eventId: UUID().uuidString, processSessionId: runtime.context.processSessionId,
                              observedAtMs: Date().timeIntervalSince1970 * 1000,
                              runtimeVersion: runtime.context.runtimeVersion, hostBuild: runtime.context.hostBuild,
                              viewId: viewId, nativeInstanceId: nil, containerKind: kind,
                              loadId: exactLoad ? loadId : nil, loadKind: exactLoad ? loadKind : nil,
                              bundle: ambiguous ? nil : bundle,
                              visibility: backgrounded ? .background : visibility,
                              quality: quality, sampling: sampling, payload: payload))
    }
}
