import Foundation
import XCTest
@testable import LynxShellKitE2ECore

final class ShellOtaRuntimeReadinessTests: XCTestCase {
    private let appID = "10020000"
    private let homeBundle = "HomePage.lynx.bundle"
    private let ecommerceBundle = "OtaEcommercePage.lynx.bundle"

    /// 真实模板字节由 scripts/native-readiness/local-template-server.mjs 提供；执行此组时必须关闭 XCTest 并行。
    func testCandidateRecoveryReplacesOnlyFailedSnapshotAndKeepsSameSessionOnStableRelease() async throws {
        try await setFixture(phase: "v1")
        let fixture = try makeRuntime()
        defer { fixture.cleanup() }

        let stable = try await promoteCurrentV1(using: fixture.runtime)
        XCTAssertEqual(stable.releaseId, "template-v1")

        try await setFixture(phase: "v2")
        let syncedV2 = await fixture.runtime.synchronizeAllBundles()
        XCTAssertTrue(syncedV2)

        let session = "candidate-recovery-\(UUID().uuidString)"
        let candidateResult = try await fixture.runtime.resolvePage(
            lynxAppId: appID,
            bundleName: homeBundle,
            navigationSessionID: session
        )
        let candidate = try unwrap(candidateResult)
        XCTAssertEqual(candidate.releaseId, "template-v2")
        XCTAssertEqual(candidate.source, "candidate_trial")
        let failedSnapshotID = try unwrap(candidate.navigationSnapshotID)
        let failedSnapshotWasActive = await fixture.runtime.isNavigationSnapshotActive(failedSnapshotID)
        XCTAssertTrue(failedSnapshotWasActive)

        let recovered = try await fixture.runtime.recoverFailedCandidate(
            lynxAppId: appID,
            expectedReleaseId: candidate.releaseId,
            expectedIdentityEpoch: candidate.userIdentityEpoch
        )
        XCTAssertTrue(recovered)
        let failedSnapshotIsActive = await fixture.runtime.isNavigationSnapshotActive(failedSnapshotID)
        XCTAssertFalse(failedSnapshotIsActive)
        let stableCurrentResult = try await fixture.runtime.resolveCurrent(lynxAppId: appID, bundleName: homeBundle)
        let stableCurrent = try unwrap(stableCurrentResult)
        XCTAssertEqual(stableCurrent.releaseId, "template-v1")

        // 失效 callback 之后新一轮同步可产生 pending candidate，但恢复页只能固定 current。
        let resynced = await fixture.runtime.synchronizeAllBundles()
        XCTAssertTrue(resynced)
        let afterRecoverySnapshot = try await appSnapshot(runtime: fixture.runtime)
        XCTAssertEqual(afterRecoverySnapshot.candidate?.status, "pending")

        let recoveredRootResult = try await fixture.runtime.resolveRecoveredCurrent(
            lynxAppId: appID,
            bundleName: homeBundle,
            navigationSessionID: session
        )
        let recoveredRoot = try unwrap(recoveredRootResult)
        XCTAssertEqual(recoveredRoot.releaseId, "template-v1")
        let stableSnapshotID = try unwrap(recoveredRoot.navigationSnapshotID)
        let stableSnapshotIsActive = await fixture.runtime.isNavigationSnapshotActive(stableSnapshotID)
        XCTAssertTrue(stableSnapshotIsActive)

        let childResult = try await fixture.runtime.resolvePage(
            lynxAppId: appID,
            bundleName: ecommerceBundle,
            navigationSessionID: session
        )
        let child = try unwrap(childResult)
        XCTAssertEqual(child.releaseId, "template-v1")
        XCTAssertEqual(child.navigationSnapshotID, stableSnapshotID)
        await fixture.runtime.releaseNavigationSnapshot(navigationSessionID: session)
    }

    func testLateCandidateFailureAndConfirmCannotRollBackPromotedCurrentFromAnotherPage() async throws {
        try await setFixture(phase: "v1")
        let fixture = try makeRuntime()
        defer { fixture.cleanup() }
        _ = try await promoteCurrentV1(using: fixture.runtime)

        try await setFixture(phase: "v2")
        let syncedV2 = await fixture.runtime.synchronizeAllBundles()
        XCTAssertTrue(syncedV2)

        let firstSession = "candidate-a-\(UUID().uuidString)"
        let secondSession = "candidate-b-\(UUID().uuidString)"
        let firstResult = try await fixture.runtime.resolvePage(
            lynxAppId: appID,
            bundleName: homeBundle,
            navigationSessionID: firstSession
        )
        let first = try unwrap(firstResult)
        let secondResult = try await fixture.runtime.resolvePage(
            lynxAppId: appID,
            bundleName: ecommerceBundle,
            navigationSessionID: secondSession
        )
        let second = try unwrap(secondResult)
        XCTAssertEqual(first.releaseId, "template-v2")
        XCTAssertEqual(second.releaseId, "template-v2")
        let firstSnapshotID = try unwrap(first.navigationSnapshotID)

        let promoted = try await fixture.runtime.confirmCandidateHealthy(
            lynxAppId: appID,
            expectedReleaseId: second.releaseId,
            expectedIdentityEpoch: second.userIdentityEpoch
        )
        XCTAssertTrue(promoted)
        let promotedCurrentResult = try await fixture.runtime.resolveCurrent(lynxAppId: appID, bundleName: homeBundle)
        let promotedCurrent = try unwrap(promotedCurrentResult)
        XCTAssertEqual(promotedCurrent.releaseId, "template-v2")

        // A 的迟到 failure 与重复 health 只会命中相同已提交版本，不能回滚 B 已确认的 current。
        let recovered = try await fixture.runtime.recoverFailedCandidate(
            lynxAppId: appID,
            expectedReleaseId: first.releaseId,
            expectedIdentityEpoch: first.userIdentityEpoch
        )
        XCTAssertTrue(recovered)
        let duplicateConfirmation = try await fixture.runtime.confirmCandidateHealthy(
            lynxAppId: appID,
            expectedReleaseId: first.releaseId,
            expectedIdentityEpoch: first.userIdentityEpoch
        )
        XCTAssertTrue(duplicateConfirmation)
        let currentAfterLateCallbacksResult = try await fixture.runtime.resolveCurrent(lynxAppId: appID, bundleName: homeBundle)
        let currentAfterLateCallbacks = try unwrap(currentAfterLateCallbacksResult)
        XCTAssertEqual(currentAfterLateCallbacks.releaseId, "template-v2")
        let firstSnapshotIsActive = await fixture.runtime.isNavigationSnapshotActive(firstSnapshotID)
        XCTAssertTrue(firstSnapshotIsActive)

        let childResult = try await fixture.runtime.resolvePage(
            lynxAppId: appID,
            bundleName: ecommerceBundle,
            navigationSessionID: firstSession
        )
        let child = try unwrap(childResult)
        XCTAssertEqual(child.releaseId, "template-v2")
        await fixture.runtime.releaseNavigationSnapshot(navigationSessionID: firstSession)
        await fixture.runtime.releaseNavigationSnapshot(navigationSessionID: secondSession)
    }

    func testCandidateWithoutRequestedTemplateBundleRemainsPending() async throws {
        try await setFixture(phase: "v1")
        let fixture = try makeRuntime()
        defer { fixture.cleanup() }

        // 与 LynxRouter 安装顺序一致：先登记真实 App Bundle baseline，再做 host 同步。
        await fixture.runtime.registerEmbeddedReleases()
        let embeddedBeforeResult = try await fixture.runtime.resolveCurrent(lynxAppId: appID, bundleName: homeBundle)
        let embeddedBefore = try unwrap(embeddedBeforeResult)
        XCTAssertEqual(embeddedBefore.source, "embedded_baseline")
        let synced = await fixture.runtime.synchronizeAllBundles()
        XCTAssertTrue(synced)
        let storageBeforeMissingPage = try await appSnapshot(runtime: fixture.runtime)
        let baselinePointer = try XCTUnwrap(storageBeforeMissingPage.state?.currentReleaseId)
        let result = try await fixture.runtime.resolvePage(
            lynxAppId: appID,
            bundleName: "MissingPage.lynx.bundle",
            navigationSessionID: "missing-\(UUID().uuidString)"
        )
        XCTAssertNil(result)

        let snapshot = try await appSnapshot(runtime: fixture.runtime)
        let embeddedAfterResult = try await fixture.runtime.resolveCurrent(lynxAppId: appID, bundleName: homeBundle)
        let embeddedAfter = try unwrap(embeddedAfterResult)
        XCTAssertEqual(embeddedAfter.source, "embedded_baseline")
        XCTAssertEqual(embeddedAfter.releaseId, embeddedBefore.releaseId)
        // State 的 embedded 指针与 App 内资源清单身份分属两层，分别验证它们没有变化。
        XCTAssertEqual(snapshot.state?.currentReleaseId, baselinePointer)
        XCTAssertNotEqual(snapshot.state?.currentReleaseId, "template-v1")
        XCTAssertEqual(snapshot.candidate?.releaseId, "template-v1")
        XCTAssertEqual(snapshot.candidate?.status, "pending")
    }

    private func promoteCurrentV1(using runtime: LynxOtaRuntime) async throws -> PreparedOtaBundle {
        let synced = await runtime.synchronizeAllBundles()
        XCTAssertTrue(synced)
        let session = "promote-v1-\(UUID().uuidString)"
        let candidateResult = try await runtime.resolvePage(
            lynxAppId: appID,
            bundleName: homeBundle,
            navigationSessionID: session
        )
        let candidate = try unwrap(candidateResult)
        XCTAssertEqual(candidate.releaseId, "template-v1")
        XCTAssertEqual(candidate.source, "candidate_trial")
        let promoted = try await runtime.confirmCandidateHealthy(
            lynxAppId: appID,
            expectedReleaseId: candidate.releaseId,
            expectedIdentityEpoch: candidate.userIdentityEpoch
        )
        XCTAssertTrue(promoted)
        await runtime.releaseNavigationSnapshot(navigationSessionID: session)
        return candidate
    }

    private func makeRuntime() throws -> RuntimeFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shell-ota-readiness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let runtime = try LynxOtaRuntime(configuration: LynxOtaConfiguration(
            apiBaseURL: fixtureOrigin,
            hostApp: "capp",
            defaultLynxAppId: appID,
            environment: "TEST",
            appVersion: "1.0.0",
            buildNumber: "150",
            lynxSDKVersion: "4.1.0",
            clientToken: "readiness-fixture-only",
            storageDirectory: directory,
            pageRefreshInterval: 0,
            candidateActivationEnabled: true,
            storeVersion: .v3,
            allowLocalHTTPForTest: true,
            versionCode: "150"
        ))
        return RuntimeFixture(directory: directory, runtime: runtime)
    }

    private func appSnapshot(runtime: LynxOtaRuntime) async throws -> OtaStorageAppSnapshot {
        let storageResult = try await runtime.storageSnapshot()
        let storage = try unwrap(storageResult)
        return try unwrap(storage.apps.first { $0.appId == appID })
    }

    private var fixtureOrigin: URL {
        let value = ProcessInfo.processInfo.environment["TEMPLATE_READINESS_ORIGIN"] ?? "http://127.0.0.1:60543"
        return URL(string: value)!
    }

    private func setFixture(phase: String) async throws {
        var request = URLRequest(url: fixtureOrigin.appendingPathComponent("_readiness/control"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "phase": phase,
            "offline": false,
            "resetMetrics": true
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FixtureError.controlFailed
        }
    }

    private func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw FixtureError.missingValue }
        return value
    }
}

private final class RuntimeFixture {
    let directory: URL
    let runtime: LynxOtaRuntime

    init(directory: URL, runtime: LynxOtaRuntime) {
        self.directory = directory
        self.runtime = runtime
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum FixtureError: Error {
    case controlFailed
    case missingValue
}
