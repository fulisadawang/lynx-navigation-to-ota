import Foundation
import Testing
@testable import OtaIOSSDK

@Suite("iOS OTA release leases")
struct OtaReleaseLeaseTests {
    @Test("active page lease retains old release until page closes")
    func activePageLeaseRetainsOldRelease() async throws {
        let fixture = try await makeLeaseFixture("navigation-stack")
        try await fixture.transaction.stage(fixture.release("V1"))
        _ = try await fixture.transaction.activate(scope: fixture.scope)
        let lease = try #require(
            try await fixture.transaction.acquireCurrentBundleLease(
                scope: fixture.scope,
                bundleName: leaseBundlePath
            )
        )

        try await fixture.transaction.stage(fixture.release("V2"))
        _ = try await fixture.transaction.activate(scope: fixture.scope)
        try await fixture.transaction.stage(fixture.release("V3"))
        _ = try await fixture.transaction.activate(scope: fixture.scope)

        #expect(lease.release.context.releaseId == "V1")
        #expect(FileManager.default.fileExists(atPath: fixture.releaseDirectory("V1").path))
        #expect(try String(contentsOf: lease.fileURL, encoding: .utf8) == "payload")

        await lease.close()

        #expect(!FileManager.default.fileExists(atPath: fixture.releaseDirectory("V1").path))
        #expect(try fixture.releaseNames() == Set(["V2", "V3"]))
    }

    @Test("explicit delete defers leased release deletion")
    func explicitDeleteDefersLease() async throws {
        let fixture = try await makeLeaseFixture("explicit-delete")
        try await fixture.transaction.stage(fixture.release("V1"))
        _ = try await fixture.transaction.activate(scope: fixture.scope)
        let lease = try #require(
            try await fixture.transaction.acquireCurrentBundleLease(
                scope: fixture.scope,
                bundleName: leaseBundlePath
            )
        )

        try await fixture.transaction.deleteDownloadedBundles(app: .capp, lynxAppId: leaseAppId)

        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("apps/\(leaseAppId)/state.json").path))
        #expect(FileManager.default.fileExists(atPath: fixture.releaseDirectory("V1").path))
        #expect(try String(contentsOf: lease.fileURL, encoding: .utf8) == "payload")

        await lease.close()
        await lease.close()

        #expect(!FileManager.default.fileExists(atPath: fixture.releaseDirectory("V1").path))
    }

    @Test("discarded candidate remains only while trial page lease is alive")
    func candidateLeaseDefersDiscard() async throws {
        let fixture = try await makeLeaseFixture("candidate")
        try await fixture.transaction.stage(fixture.release("V1"))
        _ = try await fixture.transaction.activate(scope: fixture.scope)
        try await fixture.transaction.stageCandidate(fixture.release("V2"))
        let lease = try #require(
            try await fixture.transaction.acquireCandidateBundleLease(
                scope: fixture.scope,
                bundleName: leaseBundlePath
            )
        )

        try await fixture.transaction.discardCandidate(scope: fixture.scope)

        #expect(FileManager.default.fileExists(atPath: fixture.releaseDirectory("V2").path))
        #expect(try fixture.releaseNames() == Set(["V1", "V2"]))

        await lease.close()

        #expect(!FileManager.default.fileExists(atPath: fixture.releaseDirectory("V2").path))
        #expect(try fixture.releaseNames() == Set(["V1"]))
    }
}

private struct LeaseFixture {
    let root: URL
    let transaction: ReleaseTransaction
    let scope: OtaReleaseScope
    let source: URL
    let checksum: String

    func release(_ releaseId: String) -> OtaInstalledRelease {
        OtaInstalledRelease(
            context: OtaCurrentReleaseContext(
                env: .test,
                app: .capp,
                lynxAppId: leaseAppId,
                releaseId: releaseId,
                platform: .ios,
                status: .active
            ),
            installedAt: Date(),
            bundles: [
                OtaInstalledBundle(
                    pageId: 1,
                    bundlePath: leaseBundlePath,
                    bundleSha256: checksum,
                    remoteURL: source,
                    localFilePath: source.path
                )
            ]
        )
    }

    func releaseDirectory(_ releaseId: String) -> URL {
        root.appendingPathComponent("apps/\(leaseAppId)/releases/\(releaseId)", isDirectory: true)
    }

    func releaseNames() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("apps/\(leaseAppId)/releases").path
        ))
    }
}

private func makeLeaseFixture(_ name: String) async throws -> LeaseFixture {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ios-lease-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.deletingLastPathComponent()
        .appendingPathComponent("ios-lease-source-\(UUID().uuidString).lynx.bundle")
    try Data("payload".utf8).write(to: source)
    let checksum = try SHA256ChecksumValidator().sha256(for: source)
    let scope = OtaReleaseScope(app: .capp, lynxAppId: leaseAppId)
    let transaction = ReleaseTransaction(store: FileOtaReleaseStore(baseDirectory: root))
    let embedded = OtaInstalledRelease(
        context: OtaCurrentReleaseContext(
            env: .test,
            app: .capp,
            lynxAppId: leaseAppId,
            releaseId: "embedded",
            platform: .ios,
            status: .active
        ),
        installedAt: Date(),
        bundles: [
            OtaInstalledBundle(
                pageId: 1,
                bundlePath: leaseBundlePath,
                bundleSha256: checksum,
                remoteURL: source,
                localFilePath: source.path
            )
        ]
    )
    try await transaction.registerEmbedded(embedded)
    return LeaseFixture(root: root, transaction: transaction, scope: scope, source: source, checksum: checksum)
}

private let leaseAppId = "10000009"
private let leaseBundlePath = "main.lynx.bundle"
