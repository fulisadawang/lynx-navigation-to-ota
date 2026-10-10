import Foundation
import UIKit
import XCTest
@testable import LynxShellKitE2ECore

@MainActor
final class BundleLoadingBenchmarkTests: XCTestCase {
    func testRealTemplatePageAndTabLoadingSegments() async throws {
        let runtime = try await PinnedBundleLoadingRuntime.make()
        let previous = LynxShell.otaRuntime()
        LynxShell.installOtaRuntime(runtime)
        defer {
            LynxBundleLoadDiagnostics.observe(nil)
            LynxRouter.setMessageHandler(nil)
            LynxShell.installOtaRuntime(previous)
        }
        let label = Bundle.main.object(forInfoDictionaryKey: "BundleLoadingRunLabel") as? String ?? "unlabeled"
        let allBundles = ["BundleLoadSmall.lynx.bundle", "BundleLoadLarge.lynx.bundle", "BundleLoadAsync.lynx.bundle"]
        let bundles = Bundle.main.object(forInfoDictionaryKey: "BundleLoadingCases") as? [String] ?? allBundles
        let containers = Bundle.main.object(forInfoDictionaryKey: "BundleLoadingContainers") as? [String] ?? ["page", "tab"]
        XCTAssertFalse(bundles.isEmpty)
        XCTAssertFalse(containers.isEmpty)
        XCTAssertTrue(bundles.allSatisfy { allBundles.contains($0) })
        XCTAssertTrue(containers.allSatisfy { ["page", "tab"].contains($0) })
        var samples: [[String: Any]] = []
        for bundle in bundles {
            for kind in containers {
                for iteration in 0..<13 {
                    let recorder = BundleLoadRecorder()
                    LynxBundleLoadDiagnostics.observe { recorder.append($0) }
                    LynxRouter.setMessageHandler { message in
                        guard message.eventName == "bundle-loading-bench.ready" else {
                            return LynxRouterMessageReply(accepted: false, message: "基准宿主仅接受 ready 验收事件")
                        }
                        recorder.acceptReady(message.payload)
                        return LynxRouterMessageReply(message: "真实模板 checksum 已收到")
                    }
                    let started = ProcessInfo.processInfo.systemUptime
                    let controller = makeController(kind: kind, bundle: bundle)
                    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                    let window = UIWindow(windowScene: scene)
                    window.frame = scene.coordinateSpace.bounds
                    window.rootViewController = UINavigationController(rootViewController: controller)
                    window.makeKeyAndVisible()
                    let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                        recorder.events.contains { $0.container == kind && $0.phase == "first_screen" }
                    }, object: nil)
                    await fulfillment(of: [ready], timeout: 30)
                    let facts = recorder.events.filter { $0.container == kind }
                    let firstScreen = try XCTUnwrap(facts.first { $0.phase == "first_screen" }, "模板首屏必须由真实 Lynx callback 到达")
                    let sameLoad = facts.filter { $0.generation == firstScreen.generation }
                    let read = try XCTUnwrap(sameLoad.first { $0.phase == "source_read_started" })
                    let completed = try XCTUnwrap(sameLoad.first { $0.phase == "source_read_completed" })
                    XCTAssertGreaterThan(try XCTUnwrap(completed.byteCount), 0)
                    if kind == "page" { XCTAssertFalse(read.onMainThread) }
                    let expectsDetachedTab = Bundle.main.object(forInfoDictionaryKey: "BundleLoadingExpectDetachedTab") as? Bool ?? false
                    if kind == "tab", expectsDetachedTab { XCTAssertFalse(read.onMainThread, "Tab 主包读取必须在后台实际执行") }
                    let businessReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in recorder.readyPayload != nil }, object: nil)
                    await fulfillment(of: [businessReady], timeout: 30)
                    let readyPayload = try XCTUnwrap(recorder.readyPayload)
                    let expected = try XCTUnwrap(runtime.expected[bundle])
                    XCTAssertEqual(readyPayload["caseName"] as? String, expected.caseName)
                    XCTAssertEqual((readyPayload["moduleCount"] as? NSNumber)?.intValue, expected.moduleCount)
                    XCTAssertEqual((readyPayload["payloadLength"] as? NSNumber)?.intValue, expected.payloadLength)
                    XCTAssertEqual((readyPayload["checksum"] as? NSNumber)?.intValue, expected.checksum)
                    var result: [String: Any] = ["label": label, "container": kind, "bundleName": bundle,
                                                "iteration": iteration, "warmup": iteration < 3,
                                                "sourceBytes": completed.byteCount!, "sourceReadOnMainThread": read.onMainThread,
                                                "readyChecksum": expected.checksum, "readyModuleCount": expected.moduleCount,
                                                "readyPayloadLength": expected.payloadLength,
                                                "openToBusinessReadyMs": (try XCTUnwrap(recorder.readyUptime) - started) * 1000,
                                                "openToFirstScreenMs": (firstScreen.uptime - started) * 1000]
                    for (name, begin, end) in [("resolveMs", "resolve_started", "resolve_completed"),
                                              ("resourcesMs", "resources_started", "resources_completed"),
                                              ("sourceReadMs", "source_read_started", "source_read_completed"),
                                              ("viewCreateMs", "view_create_started", "view_create_completed"),
                                              ("submitToFirstScreenMs", "load_submitted", "first_screen")] {
                        let a = try XCTUnwrap(sameLoad.first { $0.phase == begin })
                        let b = try XCTUnwrap(sameLoad.first { $0.phase == end })
                        result[name] = (b.uptime - a.uptime) * 1000
                    }
                    samples.append(result)
                    if iteration == 3 {
                        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                        }
                        let attachment = XCTAttachment(image: screenshot)
                        attachment.name = "\(label)-\(kind)-\(bundle)"
                        attachment.lifetime = .keepAlways
                        add(attachment)
                    }
                    window.isHidden = true
                    window.rootViewController = nil
                    // 上一 View 的关闭与 drain 完成后再测下一条，避免故意重叠的回收干扰结果。
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        }
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BundleLoading", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["label": label, "platform": "ios-simulator",
                                                              "samples": samples], options: [.sortedKeys, .prettyPrinted])
        try data.write(to: directory.appendingPathComponent(label + ".json"), options: .atomic)
        XCTAssertEqual(samples.filter { !($0["warmup"] as! Bool) }.count, bundles.count * containers.count * 10)
    }

    func testNativeTabLateResolveCannotOverwriteRefreshedGeneration() async throws {
        let runtime = try await PinnedBundleLoadingRuntime.make(deferFirstResolve: true)
        let previous = LynxShell.otaRuntime()
        LynxShell.installOtaRuntime(runtime)
        defer { LynxShell.installOtaRuntime(previous); LynxBundleLoadDiagnostics.observe(nil); LynxRouter.setMessageHandler(nil) }
        let recorder = BundleLoadRecorder()
        LynxBundleLoadDiagnostics.observe { recorder.append($0) }
        LynxRouter.setMessageHandler { _ in .init() }
        let tab = try XCTUnwrap(makeController(kind: "tab", bundle: "BundleLoadSmall.lynx.bundle") as? LynxTabViewController)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = tab
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        await runtime.waitForFirstResolve()
        tab.refreshFromCurrent()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in tab.debugState.contains("load=2;resolve=2;render=1;error=ready") }, object: nil)
        await fulfillment(of: [ready], timeout: 30)
        XCTAssertTrue(tab.debugState.contains("error=ready"), tab.debugState)
        let accepted = tab.debugState
        await runtime.finishFirstResolve()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(tab.debugState, accepted, "忽略取消而迟到的真实 lease 不能覆盖新的 Tab View")
        XCTAssertEqual(recorder.events.filter { $0.phase == "first_screen" }.count, 1)
    }

    func testOrdinaryTabSwitchesReuseLoadedViewsAndBytes() async throws {
        let runtime = try await PinnedBundleLoadingRuntime.make()
        let previous = LynxShell.otaRuntime()
        LynxShell.installOtaRuntime(runtime)
        defer { LynxShell.installOtaRuntime(previous); LynxBundleLoadDiagnostics.observe(nil); LynxRouter.setMessageHandler(nil) }
        let recorder = BundleLoadRecorder()
        LynxBundleLoadDiagnostics.observe { recorder.append($0) }
        LynxRouter.setMessageHandler { _ in .init() }
        let first = try XCTUnwrap(makeController(kind: "tab", bundle: "BundleLoadSmall.lynx.bundle") as? LynxTabViewController)
        let second = try XCTUnwrap(makeController(kind: "tab", bundle: "BundleLoadLarge.lynx.bundle") as? LynxTabViewController)
        let tabs = UITabBarController()
        tabs.viewControllers = [first, second]
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = tabs
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let firstReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in first.debugState.contains("error=ready") }, object: nil)
        await fulfillment(of: [firstReady], timeout: 30)
        XCTAssertTrue(first.debugState.contains("error=ready"), first.debugState)
        tabs.selectedIndex = 1
        let secondReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in second.debugState.contains("error=ready") }, object: nil)
        await fulfillment(of: [secondReady], timeout: 30)
        XCTAssertTrue(second.debugState.contains("error=ready"), second.debugState)
        let firstFacts = first.debugState
        let secondFacts = second.debugState
        let sourceReads = recorder.events.filter { $0.phase == "source_read_started" }.count
        for _ in 0..<10 { tabs.selectedIndex = 0; tabs.selectedIndex = 1 }
        XCTAssertEqual(first.debugState, firstFacts)
        XCTAssertEqual(second.debugState, secondFacts)
        XCTAssertEqual(sourceReads, 2)
        XCTAssertEqual(recorder.events.filter { $0.phase == "source_read_started" }.count, sourceReads)
    }

    private func makeController(kind: String, bundle: String) -> UIViewController {
        if kind == "tab" {
            return LynxTabViewController(spec: .init(tabId: "bundle-loading-" + UUID().uuidString,
                                                     bundleURL: bundle,
                                                     lynxAppId: "10030071", bundleName: bundle))
        }
        let request = LynxPageRequest(bundleURL: bundle, lynxAppId: "10030071", bundleName: bundle,
                                      routeKey: UUID().uuidString, title: "加载基准", initialData: [:], globalProps: [:],
                                      fullscreen: true, showNavigationBar: false, hideStatusBar: false, allowHTTPInDebug: true,
                                      orientation: .system, backgroundColor: "#ffffff", widthInPhysicalPixels: nil, heightInPhysicalPixels: nil)
        return LynxContainerViewController(request: request, navigationSessionID: UUID().uuidString)
    }
}

private final class BundleLoadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LynxBundleLoadEvent] = []
    private var ready: [String: Any]?
    private var readyTime: TimeInterval?

    var events: [LynxBundleLoadEvent] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func append(_ event: LynxBundleLoadEvent) {
        lock.lock(); defer { lock.unlock() }
        stored.append(event)
    }

    var readyPayload: [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return ready
    }

    var readyUptime: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return readyTime
    }

    func acceptReady(_ payload: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        ready = payload
        readyTime = ProcessInfo.processInfo.systemUptime
    }
}

/** 基准 DI 只选择真实模板文件：完整 Store stage/activate、真实 lease 和 SDK prepareResources。 */
private actor PinnedBundleLoadingRuntime: LynxBundleRuntime {
    nonisolated let expected: [String: BundleLoadingReadyPayload]
    private let transaction: ReleaseTransaction
    private let sdk: OtaSDK
    private let scope = OtaReleaseScope(app: .template, lynxAppId: "10030071")
    private let firstResolveEntered = BundleLoadingTestSignal()
    private let firstResolveReleased = BundleLoadingTestSignal()
    private let deferFirstResolve: Bool
    private var resolveCount = 0

    init(transaction: ReleaseTransaction, sdk: OtaSDK, expected: [String: BundleLoadingReadyPayload], deferFirstResolve: Bool) {
        self.transaction = transaction
        self.sdk = sdk
        self.expected = expected
        self.deferFirstResolve = deferFirstResolve
    }

    static func make(deferFirstResolve: Bool = false) async throws -> PinnedBundleLoadingRuntime {
        let fixture = try XCTUnwrap(Bundle.main.url(forResource: "BundleLoadingFixtures", withExtension: nil))
        let metadata = try JSONDecoder().decode(BundleLoadingFixtureMetadata.self, from: Data(contentsOf: fixture.appendingPathComponent("fixture-metadata.json")))
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("bundle-loading-pinned-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entries = try metadata.cases.flatMap { record in
            try record.asyncResources.map { resource in
                OtaAsyncResource(ownerBundlePath: resource.ownerBundlePath, requestKey: resource.requestKey, path: resource.path,
                                 url: try XCTUnwrap(URL(string: resource.url)), sha256: "sha256:" + resource.sha256,
                                 size: resource.size, kind: resource.kind)
            }
        }
        let manifestBytes = try JSONEncoder().encode(OtaAsyncManifest(schemaVersion: 1, entries: entries))
        let manifestFile = directory.appendingPathComponent("fixture-async.json")
        try manifestBytes.write(to: manifestFile)
        let manifestURL = URL(string: "https://fixture.invalid/async.json")!
        let reference = OtaAsyncManifestReference(url: manifestURL, sha256: OtaSidecarDisk.digest(manifestBytes), size: manifestBytes.count)
        var files: [URL: URL] = [manifestURL: manifestFile]
        for entry in entries { files[entry.url] = fixture.appendingPathComponent(entry.path) }
        let downloader = PinnedBundleLoadingDownloader(files: files)
        let asyncStore = OtaAsyncBundleStore(baseDirectory: directory, downloader: downloader)
        let sidecar = try await asyncStore.prepare(reference, appId: "10030071", owners: Set(metadata.cases.map(\.path)))
        defer { sidecar.finish() }
        let bundles = try metadata.cases.map { record in
            let file = fixture.appendingPathComponent(record.path)
            _ = try OtaSidecarDisk.verifiedData(file, sha256: "sha256:" + record.sha256, size: record.size)
            return OtaInstalledBundle(bundleName: record.path, bundleSha256: "sha256:" + record.sha256,
                                      remoteURL: URL(string: "https://fixture.invalid/" + record.path)!, localFilePath: file.path)
        }
        let store = FileOtaReleaseStore(baseDirectory: directory, version: .v3)
        let transaction = ReleaseTransaction(store: store)
        let release = OtaInstalledRelease(context: .init(env: .test, app: .template, lynxAppId: "10030071", releaseId: "pinned-template", platform: .ios, status: .active),
                                          installedAt: Date(), bundles: bundles, asyncBundleManifest: reference)
        try await transaction.stage(release)
        _ = try await transaction.activate(scope: .init(app: .template, lynxAppId: "10030071"))
        let sdk = OtaSDK(configuration: .init(apiBaseURL: URL(string: "https://fixture.invalid")!, app: .template, lynxAppId: "10030071",
                                             environment: .test, platform: .ios, appVersion: "1", buildNumber: "1",
                                             storageDirectory: directory, storeVersion: .v3), store: store, downloader: downloader)
        return .init(transaction: transaction, sdk: sdk,
                     expected: Dictionary(uniqueKeysWithValues: metadata.cases.map { ($0.path, $0.expectedReadyPayload) }),
                     deferFirstResolve: deferFirstResolve)
    }

    func prepareResources(for prepared: PreparedOtaBundle) async throws -> OtaPreparedResources? {
        guard let snapshot = prepared.resourceSnapshot else { throw OtaSidecarError.missingLocalResource }
        return try await sdk.prepareResources(release: snapshot, ownerBundlePath: prepared.bundleName)
    }
    func prepare(lynxAppId: String, bundleName: String) async throws -> PreparedOtaBundle {
        guard let result = try await resolveCurrent(lynxAppId: lynxAppId, bundleName: bundleName) else { throw OtaSidecarError.missingLocalResource }
        return result
    }
    func resolveCurrent(lynxAppId: String, bundleName: String) async throws -> PreparedOtaBundle? {
        guard lynxAppId == scope.lynxAppId else { throw OtaSidecarError.unknownRequest }
        guard let lease = try await transaction.acquireCurrentBundleLease(scope: scope, bundleName: bundleName) else { return nil }
        return .init(lynxAppId: lynxAppId, bundleName: bundleName, fileURL: lease.fileURL, releaseId: lease.release.context.releaseId,
                     source: "benchmark_pinned_fixture", releaseLease: lease, resourceSnapshot: lease.release)
    }
    func resolvePage(lynxAppId: String, bundleName: String) async throws -> PreparedOtaBundle? {
        resolveCount += 1
        if deferFirstResolve, resolveCount == 1 {
            await firstResolveEntered.signal()
            // 测试有意忽略取消，检验真正迟到的文件/lease 是否被 generation 门禁拒绝。
            await firstResolveReleased.wait()
        }
        return try await resolveCurrent(lynxAppId: lynxAppId, bundleName: bundleName)
    }
    func waitForFirstResolve() async { await firstResolveEntered.wait() }
    func finishFirstResolve() async { await firstResolveReleased.signal() }
    func refreshAppBundleIfNeeded(lynxAppId: String) async {}
    func rollback(lynxAppId: String, reason: String) async throws -> Bool { false }
    func confirmCandidateHealthy(lynxAppId: String) async throws -> Bool { false }
    func reportPageOpen(lynxAppId: String, bundleName: String) async {}
    func deleteBundles(lynxAppId: String) async throws { throw OtaSidecarError.unknownRequest }
    func deleteAllBundles() async throws { throw OtaSidecarError.unknownRequest }
}

private actor BundleLoadingTestSignal {
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var completed = false
    func signal() {
        completed = true
        let waiting = pending
        pending.removeAll()
        waiting.forEach { $0.resume() }
    }
    func wait() async {
        if completed { return }
        await withCheckedContinuation { pending.append($0) }
    }
}

private struct PinnedBundleLoadingDownloader: OtaBundleDownloading {
    let files: [URL: URL]
    func download(from remoteURL: URL, to localURL: URL) async throws {
        guard let file = files[remoteURL] else { throw OtaSidecarError.missingLocalResource }
        try FileManager.default.copyItem(at: file, to: localURL)
    }
}

private struct BundleLoadingReadyPayload: Decodable, Sendable {
    let caseName: String
    let moduleCount: Int
    let payloadLength: Int
    let checksum: Int
}

private struct BundleLoadingFixtureMetadata: Decodable {
    struct Resource: Decodable {
        let ownerBundlePath: String
        let requestKey: String
        let path: String
        let url: String
        let sha256: String
        let size: Int
        let kind: String
    }
    struct Case: Decodable {
        let path: String
        let size: Int
        let sha256: String
        let expectedReadyPayload: BundleLoadingReadyPayload
        let asyncResources: [Resource]
    }
    let cases: [Case]
}
