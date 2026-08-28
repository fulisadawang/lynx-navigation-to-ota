import Foundation
import Testing
@testable import OtaIOSSDK

@Suite("iOS OTA storage diagnostics")
struct OtaStorageDiagnosticsTests {
    @Test("empty snapshot exposes real root without creating files")
    func emptySnapshotIsReadOnly() async throws {
        let root = try diagnosticsRoot("empty")
        let transaction = ReleaseTransaction(store: FileOtaReleaseStore(baseDirectory: root))
        let before = try allRelativeFiles(root)

        let snapshot = try await transaction.storageSnapshot()

        #expect(snapshot.rootPath == root.standardizedFileURL.path)
        #expect(snapshot.totalBytes == 0)
        #expect(snapshot.fileCount == 0)
        #expect(snapshot.apps.isEmpty)
        #expect(try allRelativeFiles(root) == before)
    }

    @Test("snapshot reports state candidate lease orphan and staging")
    func snapshotReportsAllRoles() async throws {
        let fixture = try await diagnosticsFixture("roles")
        try await fixture.transaction.stage(fixture.release("V1"))
        _ = try await fixture.transaction.activate(scope: fixture.scope)
        try await fixture.transaction.stage(fixture.release("V2"))
        _ = try await fixture.transaction.activate(scope: fixture.scope)
        let lease = try #require(
            try await fixture.transaction.acquireCurrentBundleLease(
                scope: fixture.scope,
                bundleName: diagnosticsBundlePath
            )
        )
        try await fixture.transaction.stageCandidate(fixture.release("V3"))
        let orphan = fixture.root.appendingPathComponent("apps/\(diagnosticsAppId)/releases/orphan", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: orphan.appendingPathComponent("release-manifest.json"))
        let staging = fixture.root.appendingPathComponent("apps/\(diagnosticsAppId)/.staging/V4.tx-test", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: staging.appendingPathComponent("main.lynx.bundle.part"))
        let expectedBytes = try byteCount(fixture.root)
        let expectedFileCount = try allRelativeFiles(fixture.root).count

        let snapshot = try await fixture.transaction.storageSnapshot()
        let app = try #require(snapshot.apps.first { $0.appId == diagnosticsAppId })

        #expect(app.state?.currentReleaseId == "V2")
        #expect(app.state?.previousReleaseId == "V1")
        #expect(app.candidate?.releaseId == "V3")
        #expect(Set(app.releases.map(\.releaseId)) == Set(["V1", "V2", "V3", "orphan"]))
        #expect(app.releases.first { $0.releaseId == "V2" }?.roles.contains(.current) == true)
        #expect(app.releases.first { $0.releaseId == "V2" }?.roles.contains(.leased) == true)
        #expect(app.releases.first { $0.releaseId == "V1" }?.roles.contains(.previous) == true)
        #expect(app.releases.first { $0.releaseId == "V3" }?.roles.contains(.candidate) == true)
        #expect(app.releases.first { $0.releaseId == "orphan" }?.roles == Set([OtaStorageReleaseRole.orphan]))
        #expect(app.releases.first { $0.releaseId == "orphan" }?.manifestValid == false)
        #expect(app.staging.first?.transactionName == "V4.tx-test")
        #expect(app.staging.first?.files.first?.relativePath == "main.lynx.bundle.part")
        #expect(snapshot.totalBytes == expectedBytes)
        #expect(snapshot.fileCount == expectedFileCount)

        await lease.close()
    }

    @Test("same release id is visible under both app snapshots")
    func sameReleaseAcrossAppsIsVisible() async throws {
        let root = try diagnosticsRoot("two-apps")
        let first = try await diagnosticsFixture(root: root, appId: "10000009", payload: "a")
        let second = try await diagnosticsFixture(root: root, appId: "10000010", payload: "b")
        try await first.transaction.stage(first.release("V5"))
        _ = try await first.transaction.activate(scope: first.scope)
        try await second.transaction.stage(second.release("V5"))
        _ = try await second.transaction.activate(scope: second.scope)

        let snapshot = try await first.transaction.storageSnapshot()

        #expect(Set(snapshot.apps.map(\.appId)) == Set(["10000009", "10000010"]))
        #expect(snapshot.apps.allSatisfy { $0.releases.contains { $0.releaseId == "V5" && $0.roles.contains(.current) } })
    }
}

private struct DiagnosticsFixture {
    let root: URL
    let transaction: ReleaseTransaction
    let scope: OtaReleaseScope
    let source: URL
    let checksum: String

    func release(_ id: String) -> OtaInstalledRelease {
        OtaInstalledRelease(
            context: OtaCurrentReleaseContext(
                env: .test,
                app: .capp,
                lynxAppId: scope.lynxAppId,
                releaseId: id,
                platform: .ios,
                status: .active
            ),
            installedAt: Date(),
            bundles: [
                OtaInstalledBundle(
                    pageId: 1,
                    bundlePath: diagnosticsBundlePath,
                    bundleSha256: checksum,
                    remoteURL: source,
                    localFilePath: source.path
                )
            ]
        )
    }
}

private func diagnosticsFixture(_ name: String) async throws -> DiagnosticsFixture {
    try await diagnosticsFixture(root: diagnosticsRoot(name), appId: diagnosticsAppId, payload: "payload")
}

private func diagnosticsFixture(root: URL, appId: String, payload: String) async throws -> DiagnosticsFixture {
    let source = root.deletingLastPathComponent()
        .appendingPathComponent("diagnostics-source-\(appId)-\(UUID().uuidString).lynx.bundle")
    try Data(payload.utf8).write(to: source)
    let checksum = try SHA256ChecksumValidator().sha256(for: source)
    let scope = OtaReleaseScope(app: .capp, lynxAppId: appId)
    let transaction = ReleaseTransaction(store: FileOtaReleaseStore(baseDirectory: root))
    let embedded = OtaInstalledRelease(
        context: OtaCurrentReleaseContext(
            env: .test,
            app: .capp,
            lynxAppId: appId,
            releaseId: "embedded",
            platform: .ios,
            status: .active
        ),
        installedAt: Date(),
        bundles: [
            OtaInstalledBundle(
                pageId: 1,
                bundlePath: diagnosticsBundlePath,
                bundleSha256: checksum,
                remoteURL: source,
                localFilePath: source.path
            )
        ]
    )
    try await transaction.registerEmbedded(embedded)
    return DiagnosticsFixture(root: root, transaction: transaction, scope: scope, source: source, checksum: checksum)
}

private func diagnosticsRoot(_ name: String) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ios-diagnostics-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func allRelativeFiles(_ root: URL) throws -> [String] {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
        return []
    }
    return try enumerator.compactMap { item -> String? in
        guard let url = item as? URL,
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
        return String(url.path.dropFirst(root.path.count + 1))
    }.sorted()
}

private func byteCount(_ root: URL) throws -> Int64 {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
        return 0
    }
    return try enumerator.reduce(into: Int64(0)) { total, item in
        guard let url = item as? URL else { return }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
    }
}

private let diagnosticsAppId = "10000009"
private let diagnosticsBundlePath = "main.lynx.bundle"
