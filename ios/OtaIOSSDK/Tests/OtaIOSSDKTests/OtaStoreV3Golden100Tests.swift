import Foundation
import Testing
@testable import OtaIOSSDK

@Suite("iOS OTA Store v3 Golden 100")
struct OtaStoreV3Golden100Tests {
    @Test("V1 100 bundles to V2 one changed bundle only writes one CAS object")
    func oneChangedBundleIsPhysicallyIncremental() async throws {
        let fixture = try Golden100Fixture(name: "one-change")
        defer { fixture.cleanup() }

        try await fixture.transaction.registerEmbedded(fixture.embedded)
        try await fixture.transaction.stage(fixture.release(version: "V1"))
        let v1 = try await fixture.transaction.activate(scope: fixture.scope)

        let unchangedFingerprints = try Dictionary(uniqueKeysWithValues: v1.bundles
            .filter { $0.bundlePath != fixture.path(index: 50) }
            .map { ($0.bundlePath, try fixture.fileFingerprint(at: $0.localFilePath)) })

        let v1Snapshot = try await fixture.transaction.storageSnapshot()
        let v1App = try #require(v1Snapshot.apps.first { $0.appId == fixture.appId })
        #expect(v1App.objectCount == 100)
        #expect(v1App.releases.first { $0.releaseId == "V1" }?.bundleCount == 100)

        try await fixture.transaction.stage(fixture.release(version: "V2"))
        let activated = try await fixture.transaction.activate(scope: fixture.scope)

        #expect(activated.context.releaseId == "V2")
        #expect(activated.bundles.count == 100)
        let v2Snapshot = try await fixture.transaction.storageSnapshot()
        let v2App = try #require(v2Snapshot.apps.first { $0.appId == fixture.appId })
        let v2State = try #require(v2App.state)
        let v2Manifest = try #require(v2App.releases.first { $0.releaseId == "V2" })
        let v1Manifest = try #require(v2App.releases.first { $0.releaseId == "V1" })
        let metrics = try #require(v2App.lastOperation)

        #expect(v2State.currentReleaseId == "V2")
        #expect(v2State.previousReleaseId == "V1")
        #expect(v2Manifest.bundleCount == 100)
        #expect(v1Manifest.bundleCount == 100)
        #expect(v2App.objectCount == 101)
        #expect(metrics.casWriteCount == 1)
        #expect(metrics.byteCopyCount == 0)
        #expect(metrics.stateCommitCount == 1)
        #expect(metrics.manifestWriteCount == 1)
        for bundle in activated.bundles where bundle.bundlePath != fixture.path(index: 50) {
            #expect(try fixture.fileFingerprint(at: bundle.localFilePath) == unchangedFingerprints[bundle.bundlePath])
        }
        #expect(activated.bundles.allSatisfy { FileManager.default.fileExists(atPath: $0.localFilePath) })
        #expect(try await fixture.transaction.currentBundle(scope: fixture.scope, bundleName: fixture.path(index: 50)) != nil)
    }

    @Test("same App ID object is shared by V1 and V2 and lease protects V1-only object")
    func leaseProtectsObjectUntilClosed() async throws {
        let fixture = try Golden100Fixture(name: "lease-gc")
        defer { fixture.cleanup() }

        try await fixture.transaction.registerEmbedded(fixture.embedded)
        try await fixture.transaction.stage(fixture.release(version: "V1"))
        _ = try await fixture.transaction.activate(scope: fixture.scope)
        let lease = try #require(
            try await fixture.transaction.acquireCurrentBundleLease(
                scope: fixture.scope,
                bundleName: fixture.path(index: 50)
            )
        )
        #expect(FileManager.default.fileExists(atPath: lease.fileURL.path))

        try await fixture.transaction.stage(fixture.release(version: "V2"))
        _ = try await fixture.transaction.activate(scope: fixture.scope)
        try await fixture.transaction.stage(fixture.release(version: "V3"))
        _ = try await fixture.transaction.activate(scope: fixture.scope)

        let leasedSnapshot = try await fixture.transaction.storageSnapshot()
        let leasedApp = try #require(leasedSnapshot.apps.first { $0.appId == fixture.appId })
        #expect(leasedApp.releases.contains { $0.releaseId == "V1" && $0.roles.contains(.leased) })
        #expect(leasedApp.objects.contains { $0.objectId == fixture.digest(index: 50, version: "V1") })

        await lease.close()
        try await fixture.transaction.pruneAllUnreferencedReleases()
        let releasedSnapshot = try await fixture.transaction.storageSnapshot()
        let releasedApp = try #require(releasedSnapshot.apps.first { $0.appId == fixture.appId })
        #expect(!releasedApp.releases.contains { $0.releaseId == "V1" })
        #expect(!releasedApp.objects.contains { $0.objectId == fixture.digest(index: 50, version: "V1") })
        #expect(releasedApp.objectCount == 100)
    }

    @Test("V1→V2 显式删除后，active lease 仍可读并延迟回收 V1")
    func explicitDeleteDefersLeasedV1ReleaseAndObject() async throws {
        let fixture = try Golden100Fixture(name: "explicit-delete-lease")
        defer { fixture.cleanup() }

        try await fixture.transaction.registerEmbedded(fixture.embedded)
        try await fixture.transaction.stage(fixture.release(version: "V1"))
        _ = try await fixture.transaction.activate(scope: fixture.scope)

        let leasedBundleName = fixture.path(index: 50)
        let lease = try #require(
            try await fixture.transaction.acquireCurrentBundleLease(
                scope: fixture.scope,
                bundleName: leasedBundleName
            )
        )
        let v1ObjectId = fixture.digest(index: 50, version: "V1")
        let v1Bytes = try Data(contentsOf: fixture.sourceURLFor(index: 50, version: "V1"))
        #expect(lease.release.context.releaseId == "V1")
        #expect(try Data(contentsOf: lease.fileURL) == v1Bytes)

        try await fixture.transaction.stage(fixture.release(version: "V2"))
        _ = try await fixture.transaction.activate(scope: fixture.scope)
        #expect(await fixture.transaction.current(scope: fixture.scope)?.context.releaseId == "V2")

        try await fixture.transaction.deleteDownloadedBundles(app: .capp, lynxAppId: fixture.appId)

        #expect(await fixture.transaction.current(scope: fixture.scope)?.context.releaseId == "embedded-golden")
        let deletedSnapshot = try await fixture.transaction.storageSnapshot()
        let deletedApp = try #require(deletedSnapshot.apps.first { $0.appId == fixture.appId })
        let leasedRelease = try #require(deletedApp.releases.first { $0.releaseId == "V1" })
        let leasedObject = try #require(deletedApp.objects.first { $0.objectId == v1ObjectId })
        #expect(leasedRelease.roles.contains(.leased))
        #expect(leasedObject.roles.contains(.leased))
        #expect(leasedObject.referencedReleaseIds == ["V1"])
        #expect(try Data(contentsOf: lease.fileURL) == v1Bytes)
        #expect(try await fixture.transaction.existingObjectURL(
            scope: fixture.scope,
            objectId: v1ObjectId,
            expectedSize: Int64(v1Bytes.count)
        ) == lease.fileURL)

        await lease.close()

        let releasedSnapshot = try await fixture.transaction.storageSnapshot()
        let releasedApp = try #require(releasedSnapshot.apps.first { $0.appId == fixture.appId })
        #expect(!releasedApp.releases.contains { $0.releaseId == "V1" })
        #expect(!releasedApp.objects.contains { $0.objectId == v1ObjectId })
        #expect(!FileManager.default.fileExists(atPath: lease.fileURL.path))
        #expect(try await fixture.transaction.existingObjectURL(
            scope: fixture.scope,
            objectId: v1ObjectId,
            expectedSize: Int64(v1Bytes.count)
        ) == nil)
    }

    @Test("回滚到历史 release 时复用同一 App ID 的 CAS 对象")
    func rollbackReusesHistoricalCASObject() async throws {
        let fixture = try Golden100Fixture(name: "sdk-cas-reuse")
        defer { fixture.cleanup() }

        let api = Golden100LatestAPIClient(latest: fixture.latest(version: "V1"))
        let downloader = RecordingBundleDownloader()
        let sdk = OtaSDK(
            configuration: OtaSDKConfiguration(
                apiBaseURL: URL(string: "http://127.0.0.1:18765")!,
                app: .capp,
                lynxAppId: fixture.appId,
                environment: .test,
                appVersion: "1.0.0",
                buildNumber: "100",
                storageDirectory: fixture.root.appendingPathComponent("sdk-store", isDirectory: true),
                storeVersion: .v3,
                allowLocalHTTPForTest: true
            ),
            apiClient: api,
            downloader: downloader
        )
        try await sdk.initializeEmbeddedRelease(fixture.embedded)

        _ = try await sdk.updateToLatestBundleList()
        await api.setLatest(fixture.latest(version: "V2"))
        _ = try await sdk.updateToLatestBundleList()
        let downloadsAfterV2 = await downloader.downloads()
        #expect(downloadsAfterV2.count == 101)
        #expect(downloadsAfterV2.last?.lastPathComponent == "V2-050.lynx.bundle")

        await api.setLatest(fixture.latest(version: "V1"))
        let rollback = try await sdk.updateToLatestBundleList()
        guard case let .updated(_, restored, summary) = rollback else {
            Issue.record("Expected v3 rollback-to-V1 update result")
            return
        }
        #expect(restored.context.releaseId == "V1")
        #expect(summary.downloadedBundleCount == 0)
        #expect(summary.reusedBundleCount == 100)
        #expect(await downloader.downloads().count == 101)
    }

    @Test("相同 SHA 的 Bundle 在不同 App ID 下保持物理隔离")
    func sameObjectIDStaysAppScoped() async throws {
        let fixture = try Golden100Fixture(name: "app-scope")
        defer { fixture.cleanup() }

        let sharedSource = fixture.sourceURLFor(index: 0, version: "V1")
        let sharedSha = try SHA256ChecksumValidator().sha256(for: sharedSource)
        let appIDs = ["10000001", "10000002"]
        for appID in appIDs {
            let scope = OtaReleaseScope(app: .capp, lynxAppId: appID)
            let embedded = OtaInstalledRelease(
                context: OtaCurrentReleaseContext(
                    env: .test,
                    app: .capp,
                    lynxAppId: appID,
                    releaseId: "embedded-\(appID)",
                    platform: .ios,
                    status: .active
                ),
                installedAt: .now,
                bundles: []
            )
            let release = OtaInstalledRelease(
                context: OtaCurrentReleaseContext(
                    env: .test,
                    app: .capp,
                    lynxAppId: appID,
                    releaseId: "release-\(appID)",
                    platform: .ios,
                    status: .active
                ),
                installedAt: .now,
                bundles: [
                    OtaInstalledBundle(
                        bundleName: "shared.lynx.bundle",
                        bundleSha256: sharedSha,
                        remoteURL: sharedSource,
                        localFilePath: sharedSource.path,
                        pageId: 1,
                        bundlePath: "pages/\(appID)/shared.lynx.bundle"
                    )
                ]
            )
            try await fixture.transaction.registerEmbedded(embedded)
            try await fixture.transaction.stage(release)
            _ = try await fixture.transaction.activate(scope: scope)
        }

        let snapshot = try await fixture.transaction.storageSnapshot()
        let apps = snapshot.apps.filter { appIDs.contains($0.appId) }
        #expect(apps.count == 2)
        #expect(apps.allSatisfy { $0.objectCount == 1 })
        #expect(apps.allSatisfy { $0.objects.first?.objectId == sharedSha })
        #expect(Set(apps.compactMap { $0.state?.currentReleaseId }) == Set([
            "release-10000001",
            "release-10000002",
        ]))
    }

    @Test("v3 candidate 在确认前不替换 current")
    func candidateNeedsHealthyConfirmation() async throws {
        let fixture = try Golden100Fixture(name: "candidate")
        defer { fixture.cleanup() }

        try await fixture.transaction.registerEmbedded(fixture.embedded)
        try await fixture.transaction.stage(fixture.release(version: "V1"))
        _ = try await fixture.transaction.activate(scope: fixture.scope)
        try await fixture.transaction.stageCandidate(fixture.release(version: "V2"))

        let before = try #require(await fixture.transaction.current(scope: fixture.scope))
        let candidate = try #require(await fixture.transaction.candidate(scope: fixture.scope))
        #expect(before.context.releaseId == "V1")
        #expect(candidate.release.context.releaseId == "V2")
        #expect(candidate.status == .pending)

        _ = try await fixture.transaction.beginCandidateTrial(scope: fixture.scope)
        let confirmed = try await fixture.transaction.confirmCandidate(scope: fixture.scope)
        #expect(confirmed.context.releaseId == "V2")
        #expect(await fixture.transaction.current(scope: fixture.scope)?.context.releaseId == "V2")
        #expect(await fixture.transaction.candidate(scope: fixture.scope) == nil)
    }

    @Test("v3 Manifest 提交故障不会发布半成品，重试可恢复")
    func manifestCommitFaultIsRecoverable() async throws {
        let fixture = try Golden100Fixture(name: "manifest-fault")
        defer { fixture.cleanup() }

        try await fixture.transaction.registerEmbedded(fixture.embedded)
        let faulty = ReleaseTransaction(
            store: FileOtaReleaseStore(
                baseDirectory: fixture.root.appendingPathComponent("store", isDirectory: true),
                version: .v3
            ),
            faultInjector: Golden100ThrowingFaultInjector(point: .beforeManifestCommit)
        )
        do {
            try await faulty.stage(fixture.release(version: "V1"))
            Issue.record("Expected v3 Manifest commit fault")
        } catch {
            // 允许故障注入器的具体 Error 类型保持测试私有。
        }
        #expect(await fixture.transaction.current(scope: fixture.scope)?.context.releaseId == "embedded-golden")

        let restarted = ReleaseTransaction(
            store: FileOtaReleaseStore(
                baseDirectory: fixture.root.appendingPathComponent("store", isDirectory: true),
                version: .v3
            )
        )
        try await restarted.stage(fixture.release(version: "V1"))
        _ = try await restarted.activate(scope: fixture.scope)
        #expect(await restarted.current(scope: fixture.scope)?.context.releaseId == "V1")
        let snapshot = try await restarted.storageSnapshot()
        #expect(snapshot.apps.first { $0.appId == fixture.appId }?.objectCount == 100)
    }
}

private struct Golden100InjectedFault: Error, Equatable {
    let point: OtaTransactionFaultPoint
}

private final class Golden100ThrowingFaultInjector: OtaTransactionFaultInjecting, @unchecked Sendable {
    let point: OtaTransactionFaultPoint

    init(point: OtaTransactionFaultPoint) {
        self.point = point
    }

    func check(_ point: OtaTransactionFaultPoint) throws {
        if self.point == point {
            throw Golden100InjectedFault(point: point)
        }
    }
}

private actor Golden100LatestAPIClient: OtaAPIClientProtocol {
    private var current: OtaLatestBundleList

    init(latest: OtaLatestBundleList) {
        self.current = latest
    }

    func setLatest(_ latest: OtaLatestBundleList) {
        current = latest
    }

    func checkForUpdate(_ request: OtaPolicyMatchRequest) async throws -> OtaPolicyMatchResponse {
        OtaPolicyMatchResponse(
            matched: true,
            releaseId: current.releaseId,
            manifestURL: nil,
            ruleId: "golden-100"
        )
    }

    func fetchManifest(
        releaseId: String,
        env: OtaEnvironment,
        app: OtaAppID,
        lynxAppId: String,
        platform: OtaPlatform
    ) async throws -> OtaReleaseManifest {
        current.asManifest()
    }

    func fetchLatestBundleList(
        env: OtaEnvironment,
        app: OtaAppID,
        lynxAppId: String,
        platform: OtaPlatform
    ) async throws -> OtaLatestBundleList {
        current
    }

    func fetchLatestBundleLists(
        env: OtaEnvironment,
        app: OtaAppID,
        platform: OtaPlatform
    ) async throws -> OtaHostLatestBundleLists {
        OtaHostLatestBundleLists(
            env: current.env,
            app: current.app,
            platform: current.platform,
            bundleLists: [current]
        )
    }

    func reportEvent(_ payload: OtaReportPayload) async throws -> OtaReportResponse {
        OtaReportResponse(accepted: true, releaseId: payload.releaseId, event: payload.event)
    }
}

private final class Golden100Fixture: @unchecked Sendable {
    let root: URL
    let appId = "10000001"
    let scope: OtaReleaseScope
    let transaction: ReleaseTransaction
    let embedded: OtaInstalledRelease
    private let fileManager = FileManager.default
    private var sources: [String: URL] = [:]

    init(name: String) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ios-ota-v3-\(name)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        scope = OtaReleaseScope(app: .capp, lynxAppId: appId)
        transaction = ReleaseTransaction(
            store: FileOtaReleaseStore(
                baseDirectory: root.appendingPathComponent("store", isDirectory: true),
                version: .v3
            )
        )
        embedded = OtaInstalledRelease(
            context: OtaCurrentReleaseContext(
                env: .test,
                app: .capp,
                lynxAppId: appId,
                releaseId: "embedded-golden",
                platform: .ios,
                status: .active
            ),
            installedAt: Date(),
            bundles: []
        )
        try writeSources()
    }

    func cleanup() {
        try? fileManager.removeItem(at: root)
    }

    func path(index: Int) -> String {
        "pages/\(appId)/bundle-\(padded(index)).lynx.bundle"
    }

    func digest(index: Int, version: String) -> String {
        let key = "\(version)-\(padded(index))"
        return (try? SHA256ChecksumValidator().sha256(for: sourceURL(key))) ?? ""
    }

    func sourceURLFor(index: Int, version: String) -> URL {
        sourceURL(version == "V1" || index != 50
            ? "V1-\(padded(index))"
            : "V2-050")
    }

    func fileFingerprint(at path: String) throws -> String {
        let values = try fileManager.attributesOfItem(atPath: path)
        let device = (values[.systemNumber] as? NSNumber)?.stringValue ?? "no-device"
        let inode = (values[.systemFileNumber] as? NSNumber)?.stringValue ?? "no-inode"
        let size = (values[.size] as? NSNumber)?.stringValue ?? "no-size"
        let modified = (values[.modificationDate] as? Date)?.timeIntervalSince1970.description ?? "no-mtime"
        return [device, inode, size, modified].joined(separator: "|")
    }

    func latest(version: String) -> OtaLatestBundleList {
        OtaLatestBundleList(
            env: .test,
            app: .capp,
            lynxAppId: appId,
            releaseId: version,
            platform: .ios,
            status: .active,
            changedBundles: (0..<100).map { index in
                let source = sourceURL(version == "V1" || index != 50
                    ? "V1-\(padded(index))"
                    : "V2-050")
                return OtaBundleArtifact(
                    bundleName: "bundle-\(padded(index)).lynx.bundle",
                    bundleSha256: (try? SHA256ChecksumValidator().sha256(for: source)) ?? "",
                    bundleURL: source,
                    size: (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.intValue,
                    pageId: 10100000 + index,
                    bundlePath: path(index: index)
                )
            }
        )
    }

    func release(version: String) -> OtaInstalledRelease {
        let bundles = (0..<100).map { index -> OtaInstalledBundle in
            let sourceKey: String
            if version == "V1" || index != 50 {
                sourceKey = "V1-\(padded(index))"
            } else {
                sourceKey = "V2-050"
            }
            let source = sourceURL(sourceKey)
            let sha = (try? SHA256ChecksumValidator().sha256(for: source)) ?? ""
            return OtaInstalledBundle(
                pageId: 10100000 + index,
                bundlePath: path(index: index),
                bundleSha256: sha,
                remoteURL: source,
                localFilePath: source.path
            )
        }
        return OtaInstalledRelease(
            context: OtaCurrentReleaseContext(
                env: .test,
                app: .capp,
                lynxAppId: appId,
                releaseId: version,
                platform: .ios,
                status: .active
            ),
            installedAt: Date(),
            bundles: bundles
        )
    }

    private func writeSources() throws {
        for index in 0..<100 {
            let indexString = padded(index)
            try writeSource(key: "V1-\(indexString)", marker: "V1-\(indexString)")
        }
        try writeSource(key: "V2-050", marker: "V2-050")
    }

    private func writeSource(key: String, marker: String) throws {
        let file = root.appendingPathComponent("sources/\(key).lynx.bundle", isDirectory: false)
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let prefix = Data("OTA-STORE-V3-GOLDEN-\(marker)-".utf8)
        var data = prefix
        let fill = UInt8(marker.utf8.reduce(0) { ($0 + Int($1)) % 251 })
        data.append(Data(repeating: fill, count: 4096))
        try data.write(to: file)
        sources[key] = file
    }

    private func sourceURL(_ key: String) -> URL {
        sources[key] ?? root.appendingPathComponent("sources/\(key).lynx.bundle")
    }

    private func padded(_ index: Int) -> String {
        String(format: "%03d", index)
    }
}
