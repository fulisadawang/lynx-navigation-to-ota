import Foundation

/// 不依赖 CocoaPods/Lynx 的 Phase 1 Alpha 纯 Swift smoke test。
/// 运行方式：swiftc TelemetryModels.swift TelemetryCoordinator.swift TelemetryCoreSmoke.swift -o /tmp/lynx-telemetry-smoke && /tmp/lynx-telemetry-smoke
@main
struct TelemetryCoreSmoke {
    static func main() {
        let sink = LynxDebugTelemetrySink(maxEvents: 100)
        let coordinator = LynxTelemetryCoordinator(configuration: LynxTelemetryConfiguration(sink: sink))
        let identity = LynxTelemetryIdentity(
            navigationSessionId: "session-1",
            entryId: "entry-1",
            pageViewId: "page-1",
            renderAttemptId: "attempt-1"
        )
        let attempted = LynxAttemptedBundleSnapshot(
            source: .ota,
            bundleName: "home.lynx.bundle",
            telemetryRouteKey: "10000001/home.lynx.bundle",
            lynxAppId: "10000001",
            candidateReleaseId: "release-1",
            expectedSha256: String(repeating: "a", count: 64)
        )
        let page = coordinator.startPage(identity: identity, attemptedBundle: attempted)
        precondition(page.pageState == .registered)
        precondition(coordinator.resolve(
            pageViewId: page.pageViewId,
            snapshot: LynxResolvedBundleSnapshot(
                source: .ota,
                bundleName: "home.lynx.bundle",
                telemetryRouteKey: "10000001/home.lynx.bundle",
                lynxAppId: "10000001",
                releaseId: "release-1",
                bundleSha256: String(repeating: "a", count: 64),
                internalLocalPath: "/private/path/must-not-serialize"
            ),
            renderAttemptId: "attempt-1"
        ))
        coordinator.markPageVisible(page.pageViewId)
        coordinator.markFirstScreen(pageViewId: page.pageViewId, renderAttemptId: "attempt-1")
        coordinator.markFirstScreen(pageViewId: page.pageViewId, renderAttemptId: "attempt-1")
        precondition(sink.snapshot().filter { $0.eventName == "lynx.ota.page_open" }.count == 1)
        precondition(coordinator.dropStaleCallback(pageViewId: page.pageViewId, renderAttemptId: "stale", generation: nil))
        coordinator.onApplicationBackground()
        coordinator.markPageHidden(page.pageViewId)
        coordinator.markPageDestroyed(page.pageViewId)
        let encoded = try! JSONEncoder().encode(page.resolvedBundle!)
        precondition(String(data: encoded, encoding: .utf8)!.contains("internalLocalPath") == false)
        let encodedEvent = try! JSONEncoder().encode(sink.snapshot().first { $0.eventName == "lynx.ota.page_open" }!)
        let eventJson = String(data: encodedEvent, encoding: .utf8)!
        precondition(eventJson.contains("lifecycle"))
        precondition(eventJson.contains("privacy"))
        precondition(eventJson.contains("attemptedBundleSnapshot"))
        precondition(eventJson.contains("resolvedBundleSnapshot"))
        precondition(eventJson.contains("internalLocalPath") == false)
        let eventObject = try! JSONSerialization.jsonObject(with: encodedEvent) as! [String: Any]
        precondition(eventObject["pageState"] == nil)
        precondition(eventObject["appState"] == nil)
        print("TelemetryCoreSmoke PASS events=\(sink.snapshot().count)")
    }
}
