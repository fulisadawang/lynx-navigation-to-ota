import Foundation
import Testing
@testable import OtaIOSSDK

@Suite("iOS OTA Store v2 retention")
struct OtaStoreV2RetentionTests {
    @Test("same release id is physically isolated by app id")
    func sameReleaseIdIsIsolated() async throws {
        let root = try makeStoreDirectory("same-release-two-apps")
        let transaction = ReleaseTransaction(store: FileOtaReleaseStore(baseDirectory: root))
        let appA = try makeFixture(root: root, appId: "10000009", embeddedId: "embedded-a", payload: "bundle-a")
        let appB = try makeFixture(root: root, appId: "10000010", embeddedId: "embedded-b", payload: "bundle-b")
        try await transaction.registerEmbedded(appA.embedded)
        try await transaction.registerEmbedded(appB.embedded)

        try await transaction.stage(appA.release("V5"))
        _ = try await transaction.activate(scope: appA.scope)
        try await transaction.stage(appB.release("V5"))
        _ = try await transaction.activate(scope: appB.scope)

        let bundleA = try #require(await transaction.currentBundle(scope: appA.scope, bundleName: bundlePath))
        let bundleB = try #require(await transaction.currentBundle(scope: appB.scope, bundleName: bundlePath))
        #expect(try String(contentsOf: bundleA, encoding: .utf8) == "bundle-a")
        #expect(try String(contentsOf: bundleB, encoding: .utf8) == "bundle-b")
        #expect(bundleA.standardizedFileURL == root.appendingPathComponent("apps/10000009/releases/V5/main.lynx.bundle"))
        #expect(bundleB.standardizedFileURL == root.appendingPathComponent("apps/10000010/releases/V5/main.lynx.bundle"))
    }

    @Test("ten activations retain only current and previous")
    func tenActivationsAreBounded() async throws {
        let root = try makeStoreDirectory("bounded-normal-retention")
        let transaction = ReleaseTransaction(store: FileOtaReleaseStore(baseDirectory: root))
        let fixture = try makeFixture(root: root, appId: appAId, embeddedId: "embedded", payload: "stable")
        try await transaction.registerEmbedded(fixture.embedded)

        for version in 1...10 {
            try await transaction.stage(fixture.release("V\(version)"))
            _ = try await transaction.activate(scope: fixture.scope)
        }

        #expect(await transaction.current(scope: fixture.scope)?.context.releaseId == "V10")
        #expect(try releaseNames(root: root, appId: appAId) == Set(["V9", "V10"]))
        let stateURL = root.appendingPathComponent("apps/\(appAId)/state.json")
        let state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        #expect(state["schemaVersion"] as? Int == 2)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("releases").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("states").path))
    }

    @Test("candidate retains at most current previous and one candidate")
    func candidateRetentionIsBounded() async throws {
        let root = try makeStoreDirectory("bounded-candidate-retention")
        let transaction = ReleaseTransaction(store: FileOtaReleaseStore(baseDirectory: root))
        let fixture = try makeFixture(root: root, appId: appAId, embeddedId: "embedded", payload: "stable")
        try await transaction.registerEmbedded(fixture.embedded)
        for version in 1...10 {
            try await transaction.stage(fixture.release("V\(version)"))
            _ = try await transaction.activate(scope: fixture.scope)
        }

        try await transaction.stageCandidate(fixture.release("V11"))

        #expect(try releaseNames(root: root, appId: appAId) == Set(["V9", "V10", "V11"]))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("apps/\(appAId)/candidate.json").path))
        _ = try await transaction.beginCandidateTrial(scope: fixture.scope)
        _ = try await transaction.confirmCandidate(scope: fixture.scope)

        #expect(await transaction.current(scope: fixture.scope)?.context.releaseId == "V11")
        #expect(try releaseNames(root: root, appId: appAId) == Set(["V10", "V11"]))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("apps/\(appAId)/candidate.json").path))
    }

    @Test("deleting one app leaves another app with same release untouched")
    func deleteIsAppScoped() async throws {
        let root = try makeStoreDirectory("delete-isolation")
        let transaction = ReleaseTransaction(store: FileOtaReleaseStore(baseDirectory: root))
        let appA = try makeFixture(root: root, appId: appAId, embeddedId: "embedded-a", payload: "bundle-a")
        let appB = try makeFixture(root: root, appId: appBId, embeddedId: "embedded-b", payload: "bundle-b")
        try await transaction.registerEmbedded(appA.embedded)
        try await transaction.registerEmbedded(appB.embedded)
        try await transaction.stage(appA.release("V5"))
        _ = try await transaction.activate(scope: appA.scope)
        try await transaction.stage(appB.release("V5"))
        _ = try await transaction.activate(scope: appB.scope)

        try await transaction.deleteDownloadedBundles(app: .capp, lynxAppId: appAId)

        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("apps/\(appAId)/state.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("apps/\(appAId)/releases/V5").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("apps/\(appBId)/state.json").path))
        let bundleB = try #require(await transaction.currentBundle(scope: appB.scope, bundleName: bundlePath))
        #expect(try String(contentsOf: bundleB, encoding: .utf8) == "bundle-b")
    }

    @Test("embedded registration never copies bundle bytes into ota store")
    func embeddedBytesAreNotCopied() async throws {
        let root = try makeStoreDirectory("embedded-direct-read")
        let transaction = ReleaseTransaction(store: FileOtaReleaseStore(baseDirectory: root))
        let fixture = try makeFixture(root: root, appId: appAId, embeddedId: "embedded", payload: "baseline")

        try await transaction.registerEmbedded(fixture.embedded)

        #expect(await transaction.current(scope: fixture.scope)?.context.releaseId == "embedded")
        let bundleFiles = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "bundle" } ?? []
        #expect(bundleFiles.isEmpty)
        #expect(try await transaction.currentBundle(scope: fixture.scope, bundleName: bundlePath) != nil)
    }

    @Test("sdk embedded initialization creates only store v2 metadata")
    func sdkInitializationDoesNotCreateLegacyPointers() async throws {
        let root = try makeStoreDirectory("sdk-no-legacy-pointers")
        let fixture = try makeFixture(root: root, appId: appAId, embeddedId: "embedded", payload: "baseline")
        let sdk = OtaSDK(
            configuration: OtaSDKConfiguration(
                apiBaseURL: URL(string: "https://ota.invalid")!,
                app: .capp,
                lynxAppId: appAId,
                environment: .test,
                platform: .ios,
                appVersion: "1.0.0",
                buildNumber: "1",
                storageDirectory: root
            ),
            store: FileOtaReleaseStore(baseDirectory: root)
        )

        try await sdk.initializeEmbeddedRelease(fixture.embedded)

        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("apps/\(appAId)/embedded.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("releases").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("states").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("current-release.json").path))
    }

    @Test("cold maintenance removes orphan and staging while preserving current")
    func coldMaintenancePrunesV2Artifacts() async throws {
        let root = try makeStoreDirectory("cold-maintenance")
        let transaction = ReleaseTransaction(store: FileOtaReleaseStore(baseDirectory: root))
        let fixture = try makeFixture(root: root, appId: appAId, embeddedId: "embedded", payload: "payload")
        try await transaction.registerEmbedded(fixture.embedded)
        try await transaction.stage(fixture.release("V1"))
        _ = try await transaction.activate(scope: fixture.scope)
        let orphan = root.appendingPathComponent("apps/\(appAId)/releases/orphan", isDirectory: true)
        let staging = root.appendingPathComponent("apps/\(appAId)/.staging/abandoned.tx", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: orphan.appendingPathComponent("old.bundle"))
        try Data("partial".utf8).write(to: staging.appendingPathComponent("partial.part"))

        try await transaction.pruneAllUnreferencedReleases()

        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("apps/\(appAId)/releases/V1").path))
        #expect(await transaction.current(scope: fixture.scope)?.context.releaseId == "V1")
    }

    @Test("cold maintenance does not guess when state is malformed")
    func malformedStateIsPreserved() async throws {
        let root = try makeStoreDirectory("cold-maintenance-malformed")
        let transaction = ReleaseTransaction(store: FileOtaReleaseStore(baseDirectory: root))
        let fixture = try makeFixture(root: root, appId: appAId, embeddedId: "embedded", payload: "payload")
        try await transaction.registerEmbedded(fixture.embedded)
        try await transaction.stage(fixture.release("V1"))
        _ = try await transaction.activate(scope: fixture.scope)
        let orphan = root.appendingPathComponent("apps/\(appAId)/releases/orphan", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: orphan.appendingPathComponent("keep.bundle"))
        try Data("malformed".utf8).write(to: root.appendingPathComponent("apps/\(appAId)/state.json"))

        try await transaction.pruneAllUnreferencedReleases()

        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("apps/\(appAId)/releases/V1").path))
        #expect(FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test("insufficient storage keeps embedded current and publishes no partial release")
    func insufficientStorageIsSafe() async throws {
        let root = try makeStoreDirectory("insufficient-storage")
        let transaction = ReleaseTransaction(
            store: FileOtaReleaseStore(baseDirectory: root),
            capacityProbe: TestCapacityProbe { _ in 0 }
        )
        let fixture = try makeFixture(root: root, appId: appAId, embeddedId: "embedded", payload: "baseline")
        try await transaction.registerEmbedded(fixture.embedded)

        await #expect(throws: OtaSDKError.self) {
            try await transaction.stage(fixture.release("V1"))
        }

        #expect(await transaction.current(scope: fixture.scope)?.context.releaseId == "embedded")
        #expect((try? releaseNames(root: root, appId: appAId))?.isEmpty == true)
        #expect((try? FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("apps/\(appAId)/.staging").path
        ))?.isEmpty == true)
    }

    @Test("orphan pruning happens before capacity preflight")
    func orphanPrunesBeforeCapacityProbe() async throws {
        let root = try makeStoreDirectory("prune-before-capacity")
        let orphan = root.appendingPathComponent("apps/\(appAId)/releases/orphan", isDirectory: true)
        let probe = TestCapacityProbe { _ in
            FileManager.default.fileExists(atPath: orphan.path) ? 0 : Int64.max
        }
        let transaction = ReleaseTransaction(
            store: FileOtaReleaseStore(baseDirectory: root),
            capacityProbe: probe
        )
        let fixture = try makeFixture(root: root, appId: appAId, embeddedId: "embedded", payload: "baseline")
        try await transaction.registerEmbedded(fixture.embedded)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: orphan.appendingPathComponent("stale.bundle"))

        try await transaction.stage(fixture.release("V1"))

        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(await transaction.staged(scope: fixture.scope)?.context.releaseId == "V1")
    }
}

private struct StoreFixture {
    let scope: OtaReleaseScope
    let embedded: OtaInstalledRelease
    let source: URL
    let checksum: String

    func release(_ releaseId: String) -> OtaInstalledRelease {
        OtaInstalledRelease(
            context: OtaCurrentReleaseContext(
                env: .test,
                app: scope.app,
                lynxAppId: scope.lynxAppId,
                releaseId: releaseId,
                platform: .ios,
                status: .active
            ),
            installedAt: Date(),
            bundles: [
                OtaInstalledBundle(
                    pageId: 1,
                    bundlePath: bundlePath,
                    bundleSha256: checksum,
                    remoteURL: source,
                    localFilePath: source.path
                )
            ]
        )
    }
}

private func makeFixture(
    root: URL,
    appId: String,
    embeddedId: String,
    payload: String
) throws -> StoreFixture {
    let source = root.deletingLastPathComponent()
        .appendingPathComponent("sources", isDirectory: true)
        .appendingPathComponent("\(appId)-\(embeddedId)-\(UUID().uuidString).lynx.bundle")
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(payload.utf8).write(to: source)
    let checksum = try SHA256ChecksumValidator().sha256(for: source)
    let scope = OtaReleaseScope(app: .capp, lynxAppId: appId)
    let embedded = OtaInstalledRelease(
        context: OtaCurrentReleaseContext(
            env: .test,
            app: .capp,
            lynxAppId: appId,
            releaseId: embeddedId,
            platform: .ios,
            status: .active
        ),
        installedAt: Date(),
        bundles: [
            OtaInstalledBundle(
                pageId: 1,
                bundlePath: bundlePath,
                bundleSha256: checksum,
                remoteURL: source,
                localFilePath: source.path
            )
        ]
    )
    return StoreFixture(scope: scope, embedded: embedded, source: source, checksum: checksum)
}

private func makeStoreDirectory(_ name: String) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ios-store-v2-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func releaseNames(root: URL, appId: String) throws -> Set<String> {
    let directory = root.appendingPathComponent("apps/\(appId)/releases", isDirectory: true)
    return Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
}

private let appAId = "10000009"
private let appBId = "10000010"
private let bundlePath = "main.lynx.bundle"

private final class TestCapacityProbe: OtaStorageCapacityProbing, @unchecked Sendable {
    private let resolver: @Sendable (URL) -> Int64

    init(_ resolver: @escaping @Sendable (URL) -> Int64) {
        self.resolver = resolver
    }

    func availableCapacity(at storageRoot: URL) -> Int64 {
        resolver(storageRoot)
    }
}
