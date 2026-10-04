import XCTest
import UIKit
import Lynx
@testable import LynxShellKitE2ECore

@MainActor
final class ShellContainerHealthIntegrationTests: XCTestCase {
    private var origin: URL { URL(string: ProcessInfo.processInfo.environment["TEMPLATE_READINESS_ORIGIN"] ?? "http://127.0.0.1:60543")! }

    func testConfirmedPageFatalKeepsCurrentAndWrittenBusinessData() async throws {
        try await control("v1")
        let (runtime, directory) = try makeRuntime()
        let synced = await runtime.synchronizeAllBundles()
        XCTAssertTrue(synced)
        let old = LynxShell.otaRuntime()
        LynxShell.installOtaRuntime(runtime)
        defer { LynxShell.installOtaRuntime(old) }
        let (page, window) = try showPage(holdHealth: false)
        defer { window.isHidden = true }
        try await waitUntil("真实首屏和模板业务信号均到达") { page.debugHealthFacts.confirmed }
        XCTAssertTrue(page.debugHealthFacts.firstScreen)
        XCTAssertTrue(page.debugHealthFacts.business)
        let dataURL = directory.appendingPathComponent("business-data.json")
        let data = Data("{\"orderDraft\":\"fixture-preserved\"}".utf8)
        try data.write(to: dataURL)
        page.debugInjectRuntimeError(NSError(domain: "ReadinessHostFault", code: 1001,
            userInfo: [NSLocalizedDescriptionKey: "测试注入：已确认后的致命错误"]))
        XCTAssertFalse(page.debugHealthFacts.loaded)
        let current = try await runtime.resolveCurrent(lynxAppId: "10020000", bundleName: "HomePage.lynx.bundle")
        XCTAssertEqual(current?.releaseId, "template-v1")
        await current?.releaseLease?.close()
        XCTAssertEqual(try Data(contentsOf: dataURL), data)
    }

    func testResourceErrorKeepsRealPageAndCurrent() async throws {
        try await control("v1")
        let (runtime, _) = try makeRuntime()
        let synced = await runtime.synchronizeAllBundles()
        XCTAssertTrue(synced)
        let old = LynxShell.otaRuntime()
        LynxShell.installOtaRuntime(runtime)
        defer { LynxShell.installOtaRuntime(old) }
        let (page, window) = try showPage(holdHealth: false)
        defer { window.isHidden = true }
        try await waitUntil("模板已确认") { page.debugHealthFacts.confirmed }
        let generation = page.debugHealthFacts.generation
        page.debugInjectRuntimeError(NSError(domain: "ReadinessResourceFault", code: LynxErrorCodeForResourceError,
            userInfo: [NSLocalizedDescriptionKey: "测试注入：图片请求失败"]))
        XCTAssertTrue(page.debugHealthFacts.loaded)
        XCTAssertTrue(page.debugHealthFacts.confirmed)
        XCTAssertEqual(page.debugHealthFacts.generation, generation)
        let current = try await runtime.resolveCurrent(lynxAppId: "10020000", bundleName: "HomePage.lynx.bundle")
        XCTAssertEqual(current?.releaseId, "template-v1")
        await current?.releaseLease?.close()
    }

    func testUnconfirmedCandidateFatalDiscardsOnceAndRebuildsStablePage() async throws {
        try await control("v1")
        let (runtime, _) = try makeRuntime()
        let firstSync = await runtime.synchronizeAllBundles()
        XCTAssertTrue(firstSync)
        let firstValue = try await runtime.resolvePage(lynxAppId: "10020000", bundleName: "HomePage.lynx.bundle")
        let first = try XCTUnwrap(firstValue)
        let confirmed = try await runtime.confirmCandidateHealthy(lynxAppId: "10020000", expectedReleaseId: first.releaseId,
            expectedIdentityEpoch: first.userIdentityEpoch)
        XCTAssertTrue(confirmed)
        await first.releaseLease?.close()
        try await control("v2")
        let secondSync = await runtime.synchronizeAllBundles()
        XCTAssertTrue(secondSync)
        let old = LynxShell.otaRuntime()
        LynxShell.installOtaRuntime(runtime)
        defer { LynxShell.installOtaRuntime(old) }
        let (page, window) = try showPage(holdHealth: true)
        defer { window.isHidden = true }
        try await waitUntil("真实候选页等待健康确认") { page.debugHealthFacts.firstScreen && page.debugHealthFacts.business }
        XCTAssertFalse(page.debugHealthFacts.confirmed)
        XCTAssertEqual(page.debugHealthFacts.source, "candidate_trial")
        let oldSnapshot = try XCTUnwrap(page.otaNavigationSnapshotID)
        let failure = NSError(domain: "ReadinessHostFault", code: 1001,
            userInfo: [NSLocalizedDescriptionKey: "测试注入：候选首屏后、确认前故障"])
        page.debugInjectRuntimeError(failure)
        page.debugInjectRuntimeError(failure)
        try await waitUntil("故障后重建稳定版本") { page.debugHealthFacts.firstScreen && page.debugHealthFacts.releaseId == "template-v1" }
        XCTAssertNotEqual(page.otaNavigationSnapshotID, oldSnapshot)
        let oldActive = await runtime.isNavigationSnapshotActive(oldSnapshot)
        XCTAssertFalse(oldActive)
        let childValue = try await runtime.resolvePage(lynxAppId: "10020000", bundleName: "OtaEcommercePage.lynx.bundle", navigationSessionID: page.navigationSessionID)
        let child = try XCTUnwrap(childValue)
        XCTAssertEqual(child.releaseId, "template-v1")
        XCTAssertEqual(child.navigationSnapshotID, page.otaNavigationSnapshotID)
        await child.releaseLease?.close()
    }

    private func makeRuntime() throws -> (LynxOtaRuntime, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("host-readiness-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let runtime = try LynxOtaRuntime(configuration: LynxOtaConfiguration(apiBaseURL: origin,
            defaultLynxAppId: "10020000", environment: "TEST", appVersion: "1.0.0", buildNumber: "150",
            clientToken: "fixture-only-native-readiness", storageDirectory: directory.appendingPathComponent("store"),
            candidateActivationEnabled: true, allowLocalHTTPForTest: true, versionCode: "150"))
        return (runtime, directory)
    }

    private func showPage(holdHealth: Bool) throws -> (LynxContainerViewController, UIWindow) {
        let request = LynxPageRequest(bundleURL: "ota://10020000/HomePage.lynx.bundle", lynxAppId: "10020000",
            bundleName: "HomePage.lynx.bundle", routeKey: "readiness-home", title: "模板测试",
            initialData: [:], globalProps: [:], fullscreen: true, showNavigationBar: false, hideStatusBar: false,
            allowHTTPInDebug: true, orientation: .system, backgroundColor: "#ffffff",
            widthInPhysicalPixels: nil, heightInPhysicalPixels: nil)
        let page = LynxContainerViewController(request: request, navigationSessionID: UUID().uuidString)
        page.debugHoldOtaHealthConfirmation = holdHealth
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UINavigationController(rootViewController: page)
        window.isHidden = false
        return (page, window)
    }

    private func waitUntil(_ description: String, condition: @escaping () -> Bool) async throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        await fulfillment(of: [expectation], timeout: 20)
        XCTAssertTrue(condition(), description)
    }

    private func control(_ phase: String) async throws {
        var request = URLRequest(url: origin.appendingPathComponent("_readiness/control"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["phase": phase, "offline": false])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
}
